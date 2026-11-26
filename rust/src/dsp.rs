use std::f64::consts::{LN_10, PI, SQRT_2};
use std::slice;

/// Computes Welch's averaged periodogram with Hann windowing and 50% overlap.
///
/// Writes frequency bins to `out_freqs`, linear PSD (uV^2/Hz) to `out_psd`,
/// log10 PSD (dB) to `out_psd_db`, and `[delta, theta, alpha, beta, gamma, total, peak_hz]`
/// to `out_bands` (length >= 7). Returns the number of frequency bins written.
#[no_mangle]
pub unsafe extern "C" fn ccs_welch_psd(
    samples: *const f64,
    len: usize,
    sample_rate: f64,
    preferred_nfft: usize,
    out_freqs: *mut f64,
    out_psd: *mut f64,
    out_psd_db: *mut f64,
    out_max_bins: usize,
    out_bands: *mut f64,
) -> usize {
    if samples.is_null()
        || out_freqs.is_null()
        || out_psd.is_null()
        || out_psd_db.is_null()
        || out_bands.is_null()
        || len < 32
        || !sample_rate.is_finite()
        || sample_rate <= 0.0
    {
        return 0;
    }

    let data = slice::from_raw_parts(samples, len);
    let max_nfft = preferred_nfft.max(32);
    let mut nfft = 32usize;
    while nfft * 2 <= max_nfft && nfft * 2 <= len {
        nfft *= 2;
    }
    if len < nfft {
        return 0;
    }

    let bins = nfft / 2 + 1;
    if bins > out_max_bins {
        return 0;
    }

    let step = (nfft / 2).max(1);
    let mut hann = Vec::with_capacity(nfft);
    let mut window_energy = 0.0f64;
    let denom = (nfft - 1) as f64;
    for i in 0..nfft {
        let w = 0.5 * (1.0 - (2.0 * PI * (i as f64) / denom).cos());
        window_energy += w * w;
        hann.push(w);
    }

    let mut accum = vec![0.0f64; bins];
    let mut real = vec![0.0f64; nfft];
    let mut imag = vec![0.0f64; nfft];
    let mut segments = 0usize;

    let scale = 1.0 / (sample_rate * window_energy);
    let mut start = 0usize;
    while start + nfft <= len {
        let mut mean = 0.0f64;
        for i in 0..nfft {
            mean += data[start + i];
        }
        mean /= nfft as f64;

        for i in 0..nfft {
            real[i] = (data[start + i] - mean) * hann[i];
            imag[i] = 0.0;
        }

        fft_in_place(&mut real, &mut imag);

        for k in 0..bins {
            let mag_sq = real[k] * real[k] + imag[k] * imag[k];
            let factor = if k == 0 || k == bins - 1 { 1.0 } else { 2.0 };
            accum[k] += mag_sq * factor * scale;
        }

        segments += 1;
        start += step;
    }

    if segments == 0 {
        return 0;
    }

    let freqs_out = slice::from_raw_parts_mut(out_freqs, bins);
    let psd_out = slice::from_raw_parts_mut(out_psd, bins);
    let db_out = slice::from_raw_parts_mut(out_psd_db, bins);
    let bands_out = slice::from_raw_parts_mut(out_bands, 7);

    let df = sample_rate / (nfft as f64);
    let inv_segments = 1.0 / (segments as f64);

    let mut delta = 0.0f64;
    let mut theta = 0.0f64;
    let mut alpha = 0.0f64;
    let mut beta = 0.0f64;
    let mut gamma = 0.0f64;
    let mut peak_hz = 0.0f64;
    let mut peak_val = -1.0f64;

    for k in 0..bins {
        let f = (k as f64) * df;
        let p = accum[k] * inv_segments;
        freqs_out[k] = f;
        psd_out[k] = p;
        db_out[k] = 10.0 * p.max(1e-12).ln() / LN_10;

        let bp = p * df;
        if (0.5..4.0).contains(&f) {
            delta += bp;
        }
        if (4.0..8.0).contains(&f) {
            theta += bp;
        }
        if (8.0..13.0).contains(&f) {
            alpha += bp;
        }
        if (13.0..30.0).contains(&f) {
            beta += bp;
        }
        if (30.0..=45.0).contains(&f) {
            gamma += bp;
        }
        if (1.0..=40.0).contains(&f) && p > peak_val {
            peak_val = p;
            peak_hz = f;
        }
    }

    bands_out[0] = delta;
    bands_out[1] = theta;
    bands_out[2] = alpha;
    bands_out[3] = beta;
    bands_out[4] = gamma;
    bands_out[5] = delta + theta + alpha + beta + gamma;
    bands_out[6] = peak_hz;

    bins
}

/// Computes signal quality & calibrated passive electrode impedance in batch for
/// `ch_count` channels stored contiguously in `raw_flat` (`ch_count * window_len`).
///
/// Writes 8 `f64` values per channel into `out_metrics`:
/// `[sqi, est_z_kohm, p2p_uv, rms_uv, line_rms_uv, hf_rms_uv, flags_bitmask, grade_int]`.
/// `flags_bitmask`: bit 0 = flatline, bit 1 = saturated.
/// `grade_int`: 0 = good, 1 = fair, 2 = poor, 3 = bad.
#[no_mangle]
pub unsafe extern "C" fn ccs_signal_quality_batch(
    raw_flat: *const f64,
    ch_count: usize,
    window_len: usize,
    sample_rate: f64,
    mains_hz: f64,
    calibration_factor: f64,
    saturated_flags: *const u8,
    out_metrics: *mut f64,
) -> bool {
    if raw_flat.is_null()
        || out_metrics.is_null()
        || ch_count == 0
        || !sample_rate.is_finite()
        || sample_rate <= 0.0
    {
        return false;
    }

    let total = ch_count * window_len;
    let raw = slice::from_raw_parts(raw_flat, total);
    let out = slice::from_raw_parts_mut(out_metrics, ch_count * 8);
    let sat_slice = if saturated_flags.is_null() {
        None
    } else {
        Some(slice::from_raw_parts(saturated_flags, ch_count))
    };

    if window_len < 16 {
        for ch in 0..ch_count {
            let base = ch * 8;
            out[base] = 0.0;
            out[base + 1] = f64::INFINITY;
            out[base + 2] = 0.0;
            out[base + 3] = 0.0;
            out[base + 4] = 0.0;
            out[base + 5] = 0.0;
            out[base + 6] = 1.0; // flatline
            out[base + 7] = 3.0; // bad
        }
        return true;
    }

    // Precompute Hann window once for the entire batch.
    let mut hann = Vec::with_capacity(window_len);
    let denom = (window_len - 1) as f64;
    for i in 0..window_len {
        hann.push(0.5 * (1.0 - (2.0 * PI * (i as f64) / denom).cos()));
    }

    let nyquist = sample_rate * 0.5;
    let mut hf_freqs = Vec::with_capacity(6);
    let mut f = 72.0f64;
    let max_hf = 108.0f64.min(nyquist - 4.0);
    while f <= max_hf {
        hf_freqs.push(f);
        f += 9.0;
    }

    for ch in 0..ch_count {
        let ch_data = &raw[ch * window_len..(ch + 1) * window_len];
        let mut sum = 0.0f64;
        let mut min_val = f64::INFINITY;
        let mut max_val = f64::NEG_INFINITY;
        let mut abs_peak = 0.0f64;

        for &v in ch_data {
            sum += v;
            if v < min_val {
                min_val = v;
            }
            if v > max_val {
                max_val = v;
            }
            let a = v.abs();
            if a > abs_peak {
                abs_peak = a;
            }
        }
        let mean = sum / (window_len as f64);

        let mut var_sum = 0.0f64;
        for &v in ch_data {
            let d = v - mean;
            var_sum += d * d;
        }
        let rms_uv = (var_sum / (window_len as f64)).sqrt();
        let p2p = max_val - min_val;
        let flatline = rms_uv < 0.08 && p2p < 0.3;
        let adc_sat = sat_slice.map(|s| s[ch] != 0).unwrap_or(false);
        let saturated = adc_sat || abs_peak > 15000.0 || p2p > 20000.0;

        let line_rms = goertzel_rms(ch_data, &hann, mean, mains_hz, sample_rate);

        let mut hf_energy_sq = 0.0f64;
        for &hf_f in &hf_freqs {
            let r = goertzel_rms(ch_data, &hann, mean, hf_f, sample_rate);
            hf_energy_sq += r * r;
        }
        let hf_rms = if hf_freqs.is_empty() {
            0.0
        } else {
            (hf_energy_sq / (hf_freqs.len() as f64)).sqrt()
        };

        let est_z = if saturated {
            f64::INFINITY
        } else if flatline {
            0.2
        } else {
            let raw_z = 1.2 + (line_rms * 2.1) + (hf_rms * 2.8);
            (raw_z * calibration_factor).clamp(0.5, 500.0)
        };

        let sqi = if saturated || flatline {
            0.0
        } else {
            let line_penalty = (line_rms / 40.0).clamp(0.0, 1.0) * 45.0;
            let amp_penalty = if p2p > 200.0 {
                ((p2p - 200.0) / 800.0).clamp(0.0, 1.0) * 35.0
            } else {
                0.0
            };
            let hf_penalty = (hf_rms / 25.0).clamp(0.0, 1.0) * 20.0;
            (100.0 - line_penalty - amp_penalty - hf_penalty).clamp(0.0, 100.0)
        };

        let grade = if saturated || flatline || sqi < 30.0 || est_z > 50.0 {
            3.0 // bad
        } else if sqi < 60.0 || est_z > 25.0 {
            2.0 // poor
        } else if sqi < 80.0 || est_z > 10.0 {
            1.0 // fair
        } else {
            0.0 // good
        };

        let flags = (if flatline { 1.0 } else { 0.0 }) + (if saturated { 2.0 } else { 0.0 });
        let base = ch * 8;
        out[base] = sqi;
        out[base + 1] = est_z;
        out[base + 2] = p2p;
        out[base + 3] = rms_uv;
        out[base + 4] = line_rms;
        out[base + 5] = hf_rms;
        out[base + 6] = flags;
        out[base + 7] = grade;
    }

    true
}

fn goertzel_rms(samples: &[f64], hann: &[f64], mean: f64, target_hz: f64, sample_rate: f64) -> f64 {
    let n = samples.len();
    if n < 8 || target_hz <= 0.0 || target_hz >= sample_rate * 0.5 {
        return 0.0;
    }
    let omega = (2.0 * PI * target_hz) / sample_rate;
    let coeff = 2.0 * omega.cos();
    let mut q1 = 0.0f64;
    let mut q2 = 0.0f64;
    for i in 0..n {
        let x = (samples[i] - mean) * hann[i];
        let q0 = coeff * q1 - q2 + x;
        q2 = q1;
        q1 = q0;
    }
    let power = (q1 * q1 + q2 * q2 - q1 * q2 * coeff).max(0.0);
    let mag = power.sqrt();
    let peak = (2.0 * mag) / (0.5 * (n as f64));
    peak / SQRT_2
}

fn fft_in_place(real: &mut [f64], imag: &mut [f64]) {
    let n = real.len();
    let mut j = 0usize;
    for i in 1..n {
        let mut bit = n >> 1;
        while (j & bit) != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            real.swap(i, j);
            imag.swap(i, j);
        }
    }

    let mut len = 2usize;
    while len <= n {
        let half = len >> 1;
        let angle_step = -2.0 * PI / (len as f64);
        let w_step_r = angle_step.cos();
        let w_step_i = angle_step.sin();
        let mut i = 0usize;
        while i < n {
            let mut wr = 1.0f64;
            let mut wi = 0.0f64;
            for k in 0..half {
                let even_idx = i + k;
                let odd_idx = even_idx + half;
                let tr = wr * real[odd_idx] - wi * imag[odd_idx];
                let ti = wr * imag[odd_idx] + wi * real[odd_idx];
                real[odd_idx] = real[even_idx] - tr;
                imag[odd_idx] = imag[even_idx] - ti;
                real[even_idx] += tr;
                imag[even_idx] += ti;
                let next_wr = wr * w_step_r - wi * w_step_i;
                wi = wr * w_step_i + wi * w_step_r;
                wr = next_wr;
            }
            i += len;
        }
        len <<= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn welch_psd_recovers_10hz_alpha_peak() {
        let sr = 250.0;
        let n = 1000;
        let samples: Vec<f64> = (0..n)
            .map(|i| 25.0 * (2.0 * PI * 10.0 * (i as f64) / sr).sin())
            .collect();
        let mut freqs = vec![0.0; 257];
        let mut psd = vec![0.0; 257];
        let mut db = vec![0.0; 257];
        let mut bands = [0.0; 7];
        let bins = unsafe {
            ccs_welch_psd(
                samples.as_ptr(),
                samples.len(),
                sr,
                512,
                freqs.as_mut_ptr(),
                psd.as_mut_ptr(),
                db.as_mut_ptr(),
                257,
                bands.as_mut_ptr(),
            )
        };
        assert_eq!(bins, 257);
        assert!((bands[6] - 10.0).abs() < 0.8);
        assert!(bands[2] / bands[5] > 0.8);
    }

    #[test]
    fn signal_quality_batch_grades_clean_noisy_flat_saturated() {
        let sr = 250.0;
        let win = 375;
        let mut raw = Vec::with_capacity(win * 4);
        // Ch 0: clean 10 Hz
        for i in 0..win {
            raw.push(18.0 * (2.0 * PI * 10.0 * (i as f64) / sr).sin());
        }
        // Ch 1: noisy 50 Hz
        for i in 0..win {
            raw.push(90.0 * (2.0 * PI * 50.0 * (i as f64) / sr).sin());
        }
        // Ch 2: flatline
        raw.extend(std::iter::repeat(12.0).take(win));
        // Ch 3: saturated flag
        for i in 0..win {
            raw.push(if i % 2 == 0 { 10.0 } else { -10.0 });
        }
        let sat = [0u8, 0u8, 0u8, 1u8];
        let mut out = vec![0.0; 32];
        let ok = unsafe {
            ccs_signal_quality_batch(
                raw.as_ptr(),
                4,
                win,
                sr,
                50.0,
                1.0,
                sat.as_ptr(),
                out.as_mut_ptr(),
            )
        };
        assert!(ok);
        assert_eq!(out[7], 0.0); // good
        assert_eq!(out[8 + 7], 3.0); // bad (50 Hz)
        assert_eq!(out[16 + 7], 3.0); // bad (flatline)
        assert_eq!(out[24 + 7], 3.0); // bad (saturated)
        assert!(out[24 + 1].is_infinite());
    }
}
