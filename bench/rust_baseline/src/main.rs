// moissanite の対抗ベースライン — 同アルゴリズムを素の Rust (std のみ,
// release+LTO) で実装する。moissanite 側 (bench/bench.rb) と同じ形・同じ
// 計算順序。horner の係数は AOT 時に未知 (引数渡し) — これが「実行時
// 特殊化を持たない AOT 言語」の一般形である。
use std::time::Instant;

fn mandel_grid(out: &mut [f64], w: i64, h: i64, x0: f64, y0: f64, dx: f64, dy: f64, limit: i64) {
    for y in 0..h {
        for x in 0..w {
            let cr = x0 + (x as f64) * dx;
            let ci = y0 + (y as f64) * dy;
            let mut zr = 0.0f64;
            let mut zi = 0.0f64;
            let mut n = 0i64;
            for i in 0..limit {
                let t = zr * zr - zi * zi + cr;
                zi = 2.0 * zr * zi + ci;
                zr = t;
                if zr * zr + zi * zi > 4.0 {
                    break;
                }
                n = i + 1;
            }
            out[(y * w + x) as usize] = n as f64;
        }
    }
}

fn horner(out: &mut [f64], xs: &[f64], coeffs: &[f64]) {
    for (o, &x) in out.iter_mut().zip(xs.iter()) {
        let mut acc = coeffs[0];
        for &c in &coeffs[1..] {
            acc = acc * x + c;
        }
        *o = acc;
    }
}

// --- 4 段のパイプラインを 3 通りに実装して「実行時合成の代償」を測る ---
//
// 1. hand_fused  : コンパイル時にパイプライン全体が見えている形。Rust が
//                  最も得意な状況 (インライン + ベクトル化 + 1 パス)。
//                  ただし段の構成はバイナリに焼き付いていて変えられない。
// 2. dyn_chain   : 段が実行時に決まる形 (Vec<Box<dyn Fn>>)。要素ごと・段ごとに
//                  間接呼び出しが入り、インラインも融合も効かない。
//                  AOT 言語が「実行時に組んだパイプライン」に払う代償。
// 3. staged      : 段ごとに配列全体を舐める (ライブラリ関数を順に呼ぶ形)。
//                  数学は同じでメモリ往復が段数倍になる。
fn hand_fused(out: &mut [f64], xs: &[f64], gain: f64) {
    for (o, &x) in out.iter_mut().zip(xs.iter()) {
        let v = x * 2.0 + 1.0;
        let v = v.abs().sqrt();
        let v = v * gain - 0.25;
        *o = v.min(3.0).max(-3.0);
    }
}

fn dyn_chain(out: &mut [f64], xs: &[f64], stages: &[Box<dyn Fn(f64) -> f64>]) {
    for (o, &x) in out.iter_mut().zip(xs.iter()) {
        let mut v = x;
        for stage in stages {
            v = stage(v);
        }
        *o = v;
    }
}

// ping-pong は 2 本のバッファの偶奇で表す (スライスは swap できないため)。
fn staged(a: &mut [f64], b: &mut [f64], xs: &[f64], stages: &[Box<dyn Fn(f64) -> f64>]) {
    for (i, stage) in stages.iter().enumerate() {
        if i == 0 {
            for (o, &v) in b.iter_mut().zip(xs.iter()) {
                *o = stage(v);
            }
        } else if i % 2 == 1 {
            for (o, &v) in a.iter_mut().zip(b.iter()) {
                *o = stage(v);
            }
        } else {
            for (o, &v) in b.iter_mut().zip(a.iter()) {
                *o = stage(v);
            }
        }
    }
}

fn bench<F: FnMut()>(label: &str, iters: u32, mut f: F) -> f64 {
    f();
    let t0 = Instant::now();
    for _ in 0..iters {
        f();
    }
    let sec = t0.elapsed().as_secs_f64() / iters as f64;
    println!("{:<44} {:>10.2} ms", label, sec * 1e3);
    sec
}

// bench.rb と同じ乱数列を再現するため、係数と xs は引数 / 決定的生成で受ける。
// 係数は argv (実行時入力 = AOT に畳み込めない)。xs は xorshift で決定生成。
fn main() {
    let coeffs: Vec<f64> = std::env::args()
        .skip(1)
        .map(|s| s.parse::<f64>().expect("coeff"))
        .collect();
    let coeffs = if coeffs.is_empty() {
        // 引数が無ければ bench.rb の Random.new(7) と無関係な既定値で走る
        // (数字の比較は bench.rb が表示する係数を渡して行うこと)。
        vec![0.5, -0.25, 0.125, 0.75, -0.5, 0.3, -0.7, 0.2, 0.9]
    } else {
        coeffs
    };

    const W: i64 = 600;
    const H: i64 = 400;
    const LIMIT: i64 = 500;
    let mut out = vec![0.0f64; (W * H) as usize];
    bench(&format!("mandelbrot {}x{} limit={}  [rust]", W, H, LIMIT), 3, || {
        mandel_grid(&mut out, W, H, -2.5, -1.0, 3.5 / W as f64, 2.0 / H as f64, LIMIT)
    });
    println!("  checksum={:.1}", out.iter().sum::<f64>());

    const N: usize = 2_000_000;
    let mut state = 0x9e3779b97f4a7c15u64;
    let mut next = || {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        (state >> 11) as f64 / (1u64 << 53) as f64 * 3.0 - 1.5
    };
    let xs: Vec<f64> = (0..N).map(|_| next()).collect();
    let mut po = vec![0.0f64; N];
    let sec = bench(
        &format!("horner deg={} n={}  [generic rust]", coeffs.len() - 1, N),
        5,
        || horner(&mut po, &xs, &coeffs),
    );
    println!(
        "  checksum={:.6}  {:.2} ns/elem",
        po.iter().sum::<f64>(),
        sec * 1e9 / N as f64
    );

    // --- パイプライン: 融合 vs 実行時合成 ---
    // gain は実行時入力 (env)。moissanite 側 bench.rb と同じ 4 段。
    let gain: f64 = std::env::var("MOISSANITE_GAIN")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.68026969420451366);
    const FN_: usize = 4_000_000;
    let fxs: Vec<f64> = (0..FN_).map(|_| next()).collect();
    let mut fout = vec![0.0f64; FN_];
    let mut ping = vec![0.0f64; FN_];
    let mut pong = vec![0.0f64; FN_];

    // hand_fused は純粋なので、black_box で囲わないと LLVM がループごと
    // 消して 0ms になる (Rust 側を不当に速く見せる測定バグ)。
    let s1 = bench("pipeline 4 stages [hand-fused rust]", 5, || {
        hand_fused(
            std::hint::black_box(&mut fout),
            std::hint::black_box(&fxs),
            std::hint::black_box(gain),
        )
    });
    println!(
        "  {:.2} ns/elem  checksum={:.6}  (段の構成はコンパイル時に固定)",
        s1 * 1e9 / FN_ as f64,
        fout.iter().sum::<f64>()
    );

    // 段を実行時に組み立てる (どの段が来るかはバイナリには入っていない)
    let stages: Vec<Box<dyn Fn(f64) -> f64>> = vec![
        Box::new(|v: f64| v * 2.0 + 1.0),
        Box::new(|v: f64| v.abs().sqrt()),
        Box::new(move |v: f64| v * gain - 0.25),
        Box::new(|v: f64| v.min(3.0).max(-3.0)),
    ];
    let s2 = bench("pipeline 4 stages [dyn-chain rust]", 5, || {
        dyn_chain(&mut fout, &fxs, &stages)
    });
    println!(
        "  {:.2} ns/elem  checksum={:.6}  (実行時合成: 間接呼び出し・融合なし)",
        s2 * 1e9 / FN_ as f64,
        fout.iter().sum::<f64>()
    );

    let s3 = bench("pipeline 4 stages [staged passes rust]", 5, || {
        staged(&mut ping, &mut pong, &fxs, &stages)
    });
    println!(
        "  {:.2} ns/elem  checksum={:.6}  (段ごとに全配列を舐める)",
        s3 * 1e9 / FN_ as f64,
        pong.iter().sum::<f64>()
    );
}
