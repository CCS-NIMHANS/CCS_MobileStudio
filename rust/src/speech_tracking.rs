use std::f64::consts::PI;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct SpeechDecodeResult {
    pub r_left: f64,
    pub r_right: f64,
    pub diff_r: f64,
    pub predicted_side: i32, // 0 = Left, 1 = Right
    pub confidence: f64,
    pub snr_db: f64,
    pub n_features: i32,
}

/// Extracts power-law-compressed, 1-8 Hz bandpass speech envelope downsampled to `target_sr` (e.g. 50 Hz).
#[no_mangle]
pub unsafe extern "C" fn ccs_speech_extract_envelope(
    pcm: *const f32,
    num_samples: usize,
    audio_sr: f64,
    target_sr: f64,
    out_env: *mut f64,
    max_out: usize,
) -> usize {
    if pcm.is_null() || out_env.is_null() || num_samples == 0 || max_out == 0 {
        return 0;
    }
    let slice = std::slice::from_raw_parts(pcm, num_samples);
    let out = std::slice::from_raw_parts_mut(out_env, max_out);
    let env = extract_envelope_impl(slice, audio_sr, target_sr);
    let count = env.len().min(max_out);
    out[..count].copy_from_slice(&env[..count]);
    count
}

pub fn extract_envelope_impl(pcm: &[f32], audio_sr: f64, target_sr: f64) -> Vec<f64> {
    if pcm.is_empty() || !audio_sr.is_finite() || audio_sr <= 0.0 || target_sr <= 0.0 {
        return Vec::new();
    }
    let step = (audio_sr / target_sr).max(1.0);
    let n_out = ((pcm.len() as f64) / step).floor() as usize;
    if n_out < 4 {
        return Vec::new();
    }

    // 1) Half-rectify + power-law compression |x|^0.6 averaged in anti-aliased downsample bins
    let mut down = Vec::with_capacity(n_out);
    for k in 0..n_out {
        let a = (k as f64 * step).floor() as usize;
        let b = (((k + 1) as f64) * step).ceil() as usize;
        let b = b.clamp(a + 1, pcm.len());
        let mut sum = 0.0;
        for &s in &pcm[a..b] {
            let v = if s.is_finite() { (s as f64).abs() } else { 0.0 };
            sum += v.powf(0.6);
        }
        down.push(sum / (b - a) as f64);
    }

    // 2) Zero-phase-like forward+backward 1-8 Hz bandpass on the 50 Hz envelope + z-score
    let bp = zero_phase_bandpass(&down, target_sr, 1.0, 8.0);
    zscore(&bp)
}

/// Decodes attended ear (Left=0 vs Right=1) using multi-lag backward TRF ridge regression
/// with 4-fold blockwise cross-validation over all EEG channels (with optional multi-feature
/// filterbank expansion for low-electrode-count setups).
#[no_mangle]
pub unsafe extern "C" fn ccs_speech_decode_block(
    eeg_flat: *const f64,
    n_samples: usize,
    n_channels: usize,
    eeg_sr: f64,
    env_left: *const f64,
    env_right: *const f64,
    n_env: usize,
    env_sr: f64,
    multi_feature: u8,
    ridge_lambda: f64,
    out_result: *mut SpeechDecodeResult,
) -> i32 {
    if eeg_flat.is_null()
        || env_left.is_null()
        || env_right.is_null()
        || out_result.is_null()
        || n_samples < 16
        || n_channels == 0
        || n_env < 16
    {
        return 0;
    }
    let eeg = std::slice::from_raw_parts(eeg_flat, n_samples * n_channels);
    let el = std::slice::from_raw_parts(env_left, n_env);
    let er = std::slice::from_raw_parts(env_right, n_env);
    let res = decode_block_impl(
        eeg,
        n_samples,
        n_channels,
        eeg_sr,
        el,
        er,
        env_sr,
        multi_feature != 0,
        ridge_lambda,
    );
    *out_result = res;
    1
}

pub fn decode_block_impl(
    eeg_flat: &[f64],
    n_samples: usize,
    n_channels: usize,
    eeg_sr: f64,
    env_left: &[f64],
    env_right: &[f64],
    env_sr: f64,
    multi_feature: bool,
    ridge_lambda: f64,
) -> SpeechDecodeResult {
    let fs_target = if env_sr.is_finite() && env_sr >= 20.0 {
        env_sr
    } else {
        50.0
    };
    let eeg_rate = if eeg_sr.is_finite() && eeg_sr >= fs_target {
        eeg_sr
    } else {
        250.0
    };
    let ratio = (eeg_rate / fs_target).max(1.0);
    let n_down_eeg = ((n_samples as f64) / ratio).floor() as usize;
    let n = n_down_eeg.min(env_left.len()).min(env_right.len());
    if n < 40 || n_channels == 0 {
        return SpeechDecodeResult::default();
    }

    // Extract & anti-alias downsample each channel [ch][n]
    let usable_ch = n_channels.min(16);
    let mut down_ch = vec![vec![0.0; n]; usable_ch];
    for c in 0..usable_ch {
        for t in 0..n {
            let a = (t as f64 * ratio).floor() as usize;
            let b = (((t + 1) as f64) * ratio).ceil() as usize;
            let b = b.clamp(a + 1, n_samples);
            let mut sum = 0.0;
            for s in a..b {
                let v = eeg_flat[s * n_channels + c];
                sum += if v.is_finite() { v } else { 0.0 };
            }
            down_ch[c][t] = sum / (b - a) as f64;
        }
    }

    // Build neural feature streams (1-8 Hz raw or 5-band multi-feature for low-electrode setups)
    let mut feat_signals: Vec<Vec<f64>> = Vec::new();
    for ch_sig in &down_ch {
        let broadband = zscore(&zero_phase_bandpass(ch_sig, fs_target, 1.0, 8.0));
        feat_signals.push(broadband.clone());
        if multi_feature {
            feat_signals.push(zscore(&zero_phase_bandpass(ch_sig, fs_target, 1.0, 4.0)));
            feat_signals.push(zscore(&zero_phase_bandpass(ch_sig, fs_target, 4.0, 8.0)));
            let alpha_band = zero_phase_bandpass(ch_sig, fs_target, 8.0, 12.0);
            let alpha_env: Vec<f64> = alpha_band.iter().map(|v| v.abs()).collect();
            feat_signals.push(zscore(&zero_phase_bandpass(&alpha_env, fs_target, 1.0, 6.0)));
            let mut deriv = vec![0.0; n];
            for i in 1..n {
                deriv[i] = broadband[i] - broadband[i - 1];
            }
            feat_signals.push(zscore(&deriv));
        }
    }

    // Limit feature count so lag matrix stays compact (<= 45 predictors total)
    let max_base = 8.min(feat_signals.len());
    let base_feats = &feat_signals[..max_base];
    // Lags forward in EEG relative to stimulus onset: 0 ms..300 ms in ~50 ms steps
    // (For backward TRF reconstructing s(t) from r(t + tau): tau >= 0 -> r[t + lag])
    let lag_step = ((0.05 * fs_target).round() as usize).max(1);
    let lags: Vec<usize> = (0..6).map(|k| k * lag_step).collect();
    let max_lag = *lags.last().unwrap_or(&0);
    if n <= max_lag + 16 {
        return SpeechDecodeResult::default();
    }
    let valid_n = n - max_lag;
    let d = base_feats.len() * lags.len();

    // Build design matrix X (valid_n x d) row-major
    let mut x_mat = vec![0.0; valid_n * d];
    for t in 0..valid_n {
        let mut col = 0;
        for f in base_feats {
            for &lag in &lags {
                x_mat[t * d + col] = f[t + lag];
                col += 1;
            }
        }
    }

    let y_left = zscore(&env_left[..valid_n]);
    let y_right = zscore(&env_right[..valid_n]);

    // Evaluate 4-fold contiguous CV backward TRF reconstruction accuracy for Left vs Right
    let lam = if ridge_lambda.is_finite() && ridge_lambda > 0.0 {
        ridge_lambda
    } else {
        12.0
    };
    let r_left = cross_validated_ridge_corr(&x_mat, &y_left, valid_n, d, lam, 4);
    let r_right = cross_validated_ridge_corr(&x_mat, &y_right, valid_n, d, lam, 4);
    let diff = r_left - r_right;
    let predicted_side = if r_left >= r_right { 0 } else { 1 };
    let confidence = (diff.abs() * 4.0).clamp(0.05, 0.99);
    let noise_r = r_left.abs().min(r_right.abs()).max(1e-3);
    let sig_r = r_left.abs().max(r_right.abs()).max(1e-3);
    let snr_db = 20.0 * (sig_r / noise_r).log10();

    SpeechDecodeResult {
        r_left,
        r_right,
        diff_r: diff,
        predicted_side,
        confidence,
        snr_db,
        n_features: d as i32,
    }
}

fn cross_validated_ridge_corr(
    x: &[f64],
    y: &[f64],
    n: usize,
    d: usize,
    lambda: f64,
    folds: usize,
) -> f64 {
    if n < folds * 8 || d == 0 {
        return 0.0;
    }
    let fold_size = n / folds;
    let mut preds = vec![0.0; n];
    for fold in 0..folds {
        let test_start = fold * fold_size;
        let test_end = if fold + 1 == folds {
            n
        } else {
            (fold + 1) * fold_size
        };

        // Accumulate X^T X + lambda * diag_scale * I and X^T y over train samples
        let mut xtx = vec![0.0; d * d];
        let mut xty = vec![0.0; d];
        let mut train_n = 0usize;
        for t in 0..n {
            if t >= test_start && t < test_end {
                continue;
            }
            train_n += 1;
            let row = &x[t * d..(t + 1) * d];
            let yt = y[t];
            for i in 0..d {
                let xi = row[i];
                xty[i] += xi * yt;
                for j in i..d {
                    xtx[i * d + j] += xi * row[j];
                }
            }
        }
        let scale = (train_n as f64).max(1.0);
        for i in 0..d {
            for j in i..d {
                xtx[j * d + i] = xtx[i * d + j];
            }
            xtx[i * d + i] += lambda * scale * 0.05 + 1e-4;
        }
        let w = solve_linear_system(&mut xtx, &mut xty, d);
        for t in test_start..test_end {
            let row = &x[t * d..(t + 1) * d];
            let mut yhat = 0.0;
            for i in 0..d {
                yhat += row[i] * w[i];
            }
            preds[t] = yhat;
        }
    }
    pearson_corr(&preds, y)
}

fn solve_linear_system(a: &mut [f64], b: &mut [f64], n: usize) -> Vec<f64> {
    for col in 0..n {
        let mut pivot = col;
        let mut max_val = a[col * n + col].abs();
        for r in (col + 1)..n {
            let v = a[r * n + col].abs();
            if v > max_val {
                max_val = v;
                pivot = r;
            }
        }
        if pivot != col {
            for j in col..n {
                a.swap(col * n + j, pivot * n + j);
            }
            b.swap(col, pivot);
        }
        let diag = a[col * n + col];
        if diag.abs() < 1e-12 {
            continue;
        }
        for r in (col + 1)..n {
            let factor = a[r * n + col] / diag;
            a[r * n + col] = 0.0;
            for j in (col + 1)..n {
                a[r * n + j] -= factor * a[col * n + j];
            }
            b[r] -= factor * b[col];
        }
    }
    let mut x = vec![0.0; n];
    for r in (0..n).rev() {
        let mut s = b[r];
        for j in (r + 1)..n {
            s -= a[r * n + j] * x[j];
        }
        let diag = a[r * n + r];
        x[r] = if diag.abs() > 1e-12 { s / diag } else { 0.0 };
    }
    x
}

fn pearson_corr(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len().min(b.len());
    if n < 2 {
        return 0.0;
    }
    let mean_a = a[..n].iter().sum::<f64>() / n as f64;
    let mean_b = b[..n].iter().sum::<f64>() / n as f64;
    let mut num = 0.0;
    let mut da = 0.0;
    let mut db = 0.0;
    for i in 0..n {
        let x = a[i] - mean_a;
        let y = b[i] - mean_b;
        num += x * y;
        da += x * x;
        db += y * y;
    }
    let den = (da * db).sqrt();
    if den < 1e-12 { 0.0 } else { (num / den).clamp(-1.0, 1.0) }
}

fn zero_phase_bandpass(sig: &[f64], fs: f64, hp_hz: f64, lp_hz: f64) -> Vec<f64> {
    let f1 = causal_bandpass(sig, fs, hp_hz, lp_hz);
    let mut rev: Vec<f64> = f1.into_iter().rev().collect();
    rev = causal_bandpass(&rev, fs, hp_hz, lp_hz);
    rev.reverse();
    rev
}

fn causal_bandpass(sig: &[f64], fs: f64, hp_hz: f64, lp_hz: f64) -> Vec<f64> {
    let n = sig.len();
    if n == 0 {
        return Vec::new();
    }
    let dt = 1.0 / fs;
    let hp_rc = 1.0 / (2.0 * PI * hp_hz.max(0.1));
    let hp_a = hp_rc / (hp_rc + dt);
    let lp_rc = 1.0 / (2.0 * PI * lp_hz.min(fs * 0.45));
    let lp_a = dt / (lp_rc + dt);

    let mut out = Vec::with_capacity(n);
    let mut prev_x = sig[0];
    let mut prev_y = 0.0;
    let mut lp_state = 0.0;
    for &x in sig {
        let hp = hp_a * (prev_y + x - prev_x);
        prev_x = x;
        prev_y = hp;
        lp_state += lp_a * (hp - lp_state);
        out.push(lp_state);
    }
    out
}

fn zscore(sig: &[f64]) -> Vec<f64> {
    if sig.is_empty() {
        return Vec::new();
    }
    let n = sig.len() as f64;
    let mean = sig.iter().sum::<f64>() / n;
    let var = sig.iter().map(|&v| (v - mean) * (v - mean)).sum::<f64>() / n;
    let sd = var.sqrt().max(1e-9);
    sig.iter().map(|&v| (v - mean) / sd).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backward_trf_decodes_attended_left_stream_on_two_electrodes() {
        let env_sr = 50.0;
        let eeg_sr = 250.0;
        let sec = 20.0;
        let n_env = (env_sr * sec) as usize;
        let n_eeg = (eeg_sr * sec) as usize;

        // Distinct speech-like syllabic envelopes (3.1 Hz left vs 4.8 Hz right)
        let env_left: Vec<f64> = (0..n_env)
            .map(|i| {
                let t = i as f64 / env_sr;
                (2.0 * PI * 3.1 * t).sin() + 0.5 * (2.0 * PI * 1.4 * t).cos()
            })
            .collect();
        let env_right: Vec<f64> = (0..n_env)
            .map(|i| {
                let t = i as f64 / env_sr;
                (2.0 * PI * 4.8 * t).sin() + 0.5 * (2.0 * PI * 2.1 * t).cos()
            })
            .collect();

        // Synthesize realistic 2-channel EEG containing a 120ms neural response tracking Left
        // plus ~18 uV ongoing background alpha/theta EEG (realistic SNR for scalp AAD).
        let n_ch = 2;
        let mut eeg_flat = vec![0.0; n_eeg * n_ch];
        let delay_samples = (0.12 * eeg_sr) as usize;
        for s in 0..n_eeg {
            let src_s = s.saturating_sub(delay_samples);
            let t_src = src_s as f64 / eeg_sr;
            let t = s as f64 / eeg_sr;
            let attended = (2.0 * PI * 3.1 * t_src).sin() + 0.5 * (2.0 * PI * 1.4 * t_src).cos();
            let alpha_noise =
                14.0 * (2.0 * PI * 10.3 * t).sin() + 9.0 * (2.0 * PI * 6.4 * t + 1.1).cos();
            let beta_noise = 7.0 * (2.0 * PI * 17.7 * t).sin();
            eeg_flat[s * n_ch] = 12.0 * attended + alpha_noise + beta_noise;
            eeg_flat[s * n_ch + 1] = -9.0 * attended - 0.7 * alpha_noise + 0.8 * beta_noise;
        }

        let res = decode_block_impl(
            &eeg_flat,
            n_eeg,
            n_ch,
            eeg_sr,
            &env_left,
            &env_right,
            env_sr,
            true,
            12.0,
        );
        assert_eq!(res.predicted_side, 0, "Expected Left focus (0), got rL={} rR={}", res.r_left, res.r_right);
        assert!(res.r_left > res.r_right + 0.15, "rL={} rR={}", res.r_left, res.r_right);
    }
}
