use std::f64::consts::PI;

/// Real-time Artifact Subspace Reconstruction (ASR) + OSCAR-style online EEG
/// cleaner (CleanLine adaptive sinusoidal subtraction, gated frontal EOG/blink
/// regression, and adaptive slew/EMG transient suppression).
pub struct OnlineEegCleaner {
    channel_count: usize,
    sample_rate: f64,

    // Feature toggles & hyperparameters
    enable_cleanline: bool,
    line_freq: f64,
    enable_asr: bool,
    asr_cutoff: f64,
    enable_eog: bool,
    enable_emg: bool,
    eog_ch_mask: u32,

    // CleanLine state: per channel [w_sin1, w_cos1, w_sin2, w_cos2]
    cleanline_weights: Vec<[f64; 4]>,
    sample_index: u64,

    // High-pass tracker (1.0 Hz) for ASR covariance & EOG envelope estimation
    hp_lp_state: Vec<f64>,
    hp_alpha: f64,

    // EOG adaptive regression
    eog_weights: Vec<Vec<f64>>,
    eog_hp_state: Vec<f64>,

    // EMG / slew-pop adaptive tracker
    prev_sample: Vec<f64>,
    ema_abs_diff: Vec<f64>,

    // ASR calibration & runtime reconstruction
    cal_buffers: Vec<Vec<f64>>,
    cal_max_samples: usize,
    cal_ready: bool,
    asr_mixing: Vec<f64>,   // M = V * sqrt(Lambda), n x n row-major
    asr_vecs: Vec<f64>,     // V, n x n row-major (cols = eigenvectors)
    asr_thresh: Vec<f64>,   // tau_i = mean_i + k * sd_i, len n
    asr_q_mat: Vec<f64>,    // Q = V * diag(1 / tau_i^2) * V^T, n x n

    // Sliding hop buffer for smooth ASR reconstruction
    win_len: usize,
    hop_len: usize,
    win_buf: Vec<Vec<f64>>,     // circular/shift history of hp samples
    raw_win_buf: Vec<Vec<f64>>, // total after cleanline/emg for drift add-back
    recon_mat: Vec<f64>,        // current n x n reconstruction matrix
    prev_recon_mat: Vec<f64>,
    hop_counter: usize,
    last_intensity: f64,
}

impl OnlineEegCleaner {
    pub fn new(channel_count: usize, sample_rate: f64) -> Self {
        let ch = channel_count.clamp(1, 32);
        let sr = if sample_rate.is_finite() && sample_rate >= 25.0 {
            sample_rate
        } else {
            250.0
        };
        let dt = 1.0 / sr;
        let rc = 1.0 / (2.0 * PI * 0.35);
        let hp_alpha = dt / (rc + dt);
        let win_len = ((0.5 * sr).round() as usize).clamp(32, 512);
        let hop_len = ((0.125 * sr).round() as usize).clamp(8, win_len / 2);
        let cal_max = ((10.0 * sr).round() as usize).clamp(win_len * 4, 4096);

        Self {
            channel_count: ch,
            sample_rate: sr,
            enable_cleanline: true,
            line_freq: 50.0,
            enable_asr: true,
            asr_cutoff: 15.0,
            enable_eog: true,
            enable_emg: true,
            eog_ch_mask: 0,
            cleanline_weights: vec![[0.0; 4]; ch],
            sample_index: 0,
            hp_lp_state: vec![0.0; ch],
            hp_alpha,
            eog_weights: vec![vec![0.0; ch]; ch],
            eog_hp_state: vec![0.0; ch],
            prev_sample: vec![0.0; ch],
            ema_abs_diff: vec![5.0; ch],
            cal_buffers: vec![Vec::with_capacity(cal_max); ch],
            cal_max_samples: cal_max,
            cal_ready: false,
            asr_mixing: identity_matrix(ch),
            asr_vecs: identity_matrix(ch),
            asr_thresh: vec![1e6; ch],
            asr_q_mat: vec![0.0; ch * ch],
            win_len,
            hop_len,
            win_buf: vec![vec![0.0; win_len]; ch],
            raw_win_buf: vec![vec![0.0; win_len]; ch],
            recon_mat: identity_matrix(ch),
            prev_recon_mat: identity_matrix(ch),
            hop_counter: 0,
            last_intensity: 0.0,
        }
    }

    pub fn set_config(
        &mut self,
        enable_cleanline: bool,
        line_freq: f64,
        enable_asr: bool,
        asr_cutoff: f64,
        enable_eog: bool,
        enable_emg: bool,
        eog_ch_mask: u32,
    ) {
        self.enable_cleanline = enable_cleanline;
        self.line_freq = if line_freq.is_finite() && line_freq >= 40.0 && line_freq <= 70.0 {
            line_freq
        } else {
            50.0
        };
        self.enable_asr = enable_asr;
        let new_cutoff = if asr_cutoff.is_finite() {
            asr_cutoff.clamp(3.0, 50.0)
        } else {
            15.0
        };
        let cutoff_changed = (self.asr_cutoff - new_cutoff).abs() > 1e-6;
        self.asr_cutoff = new_cutoff;
        self.enable_eog = enable_eog;
        self.enable_emg = enable_emg;
        self.eog_ch_mask = eog_ch_mask;
        if cutoff_changed && self.cal_ready {
            self.recompute_calibration();
        }
    }

    pub fn reset(&mut self) {
        for w in &mut self.cleanline_weights {
            *w = [0.0; 4];
        }
        self.sample_index = 0;
        self.hp_lp_state.fill(0.0);
        for row in &mut self.eog_weights {
            row.fill(0.0);
        }
        self.eog_hp_state.fill(0.0);
        self.prev_sample.fill(0.0);
        self.ema_abs_diff.fill(5.0);
        for c in &mut self.cal_buffers {
            c.clear();
        }
        self.cal_ready = false;
        self.asr_mixing = identity_matrix(self.channel_count);
        self.asr_vecs = identity_matrix(self.channel_count);
        self.asr_thresh.fill(1e6);
        self.asr_q_mat.fill(0.0);
        for c in &mut self.win_buf {
            c.fill(0.0);
        }
        for c in &mut self.raw_win_buf {
            c.fill(0.0);
        }
        self.recon_mat = identity_matrix(self.channel_count);
        self.prev_recon_mat = identity_matrix(self.channel_count);
        self.hop_counter = 0;
        self.last_intensity = 0.0;
    }

    pub fn push_calibration(&mut self, sample: &[f64]) -> i32 {
        let min_needed = (4.0 * self.sample_rate).round() as usize;
        for c in 0..self.channel_count {
            let v = sample.get(c).copied().unwrap_or(0.0);
            let clean_v = if v.is_finite() { v } else { 0.0 };
            if self.cal_buffers[c].len() < self.cal_max_samples {
                self.cal_buffers[c].push(clean_v);
            }
        }
        let len = self.cal_buffers[0].len();
        if len >= min_needed && !self.cal_ready {
            self.recompute_calibration();
        } else if self.cal_ready && len % (self.sample_rate.round() as usize).max(1) == 0 {
            self.recompute_calibration();
        }
        ((len * 100) / min_needed.max(1)).min(100) as i32
    }

    pub fn calibration_progress(&self) -> i32 {
        if self.cal_ready {
            return 100;
        }
        let min_needed = (4.0 * self.sample_rate).round() as usize;
        ((self.cal_buffers[0].len() * 100) / min_needed.max(1)).min(99) as i32
    }

    fn recompute_calibration(&mut self) {
        let ch = self.channel_count;
        let n = self.cal_buffers[0].len();
        if n < self.win_len * 2 {
            return;
        }

        // High-pass filter calibration data at 1 Hz (removes offset & drift)
        let mut hp = vec![vec![0.0; n]; ch];
        for c in 0..ch {
            let mut lp = self.cal_buffers[c][0];
            for i in 0..n {
                let x = self.cal_buffers[c][i];
                lp += self.hp_alpha * (x - lp);
                hp[c][i] = x - lp;
            }
        }

        // Collect sub-window covariances and select clean windows (trimmed by RMS)
        let step = self.win_len / 2;
        let mut sub_covs: Vec<(f64, Vec<f64>)> = Vec::new();
        let mut start = 0;
        while start + self.win_len <= n {
            let mut cov = vec![0.0; ch * ch];
            for a in 0..ch {
                for b in a..ch {
                    let mut dot = 0.0;
                    for t in start..(start + self.win_len) {
                        dot += hp[a][t] * hp[b][t];
                    }
                    let val = dot / self.win_len as f64;
                    cov[a * ch + b] = val;
                    cov[b * ch + a] = val;
                }
            }
            let trace: f64 = (0..ch).map(|c| cov[c * ch + c]).sum();
            sub_covs.push((trace, cov));
            start += step.max(1);
        }
        if sub_covs.is_empty() {
            return;
        }

        // Keep bottom 75% windows by total variance to ignore incidental artifacts during calibration
        sub_covs.sort_by(|a, b| a.0.total_cmp(&b.0));
        let keep_count = ((sub_covs.len() * 3) / 4).max(1);
        let mut c0 = vec![0.0; ch * ch];
        for (_, cov) in sub_covs.iter().take(keep_count) {
            for i in 0..cov.len() {
                c0[i] += cov[i];
            }
        }
        let inv = 1.0 / keep_count as f64;
        for v in &mut c0 {
            *v *= inv;
        }
        // Small diagonal regularization for rank-deficient inputs
        for c in 0..ch {
            c0[c * ch + c] += 1e-4;
        }

        let (evals, evecs) = jacobi_eigen_sym(&c0, ch, 80);
        // Mixing matrix M = V * sqrt(Lambda)
        let mut mixing = vec![0.0; ch * ch];
        for r in 0..ch {
            for col in 0..ch {
                mixing[r * ch + col] = evecs[r * ch + col] * evals[col].max(1e-6).sqrt();
            }
        }

        // Compute per-component RMS across kept windows
        let mut comp_rms = vec![Vec::new(); ch];
        for k in 0..keep_count {
            let (_, ref cov) = sub_covs[k];
            for comp in 0..ch {
                // v_comp^T * cov * v_comp
                let mut quad = 0.0;
                for r in 0..ch {
                    let vr = evecs[r * ch + comp];
                    for c in 0..ch {
                        quad += vr * cov[r * ch + c] * evecs[c * ch + comp];
                    }
                }
                comp_rms[comp].push(quad.max(1e-9).sqrt());
            }
        }

        let mut thresh = vec![1e6; ch];
        for comp in 0..ch {
            let vals = &mut comp_rms[comp];
            vals.sort_by(f64::total_cmp);
            let med = vals[vals.len() / 2];
            let mut abs_devs: Vec<f64> = vals.iter().map(|v| (v - med).abs()).collect();
            abs_devs.sort_by(f64::total_cmp);
            let mad = (abs_devs[abs_devs.len() / 2] * 1.4826).max(med * 0.12);
            thresh[comp] = (med + self.asr_cutoff * mad).max(1e-3);
        }

        // Q = V * diag(1 / tau_i^2) * V^T
        let mut q_mat = vec![0.0; ch * ch];
        for r in 0..ch {
            for c in 0..ch {
                let mut s = 0.0;
                for comp in 0..ch {
                    let t2 = thresh[comp] * thresh[comp];
                    s += evecs[r * ch + comp] * evecs[c * ch + comp] / t2.max(1e-9);
                }
                q_mat[r * ch + c] = s;
            }
        }

        self.asr_mixing = mixing;
        self.asr_vecs = evecs;
        self.asr_thresh = thresh;
        self.asr_q_mat = q_mat;
        self.cal_ready = true;
    }

    pub fn process_sample(&mut self, input: &[f64], output: &mut [f64]) -> f64 {
        let ch = self.channel_count;
        let t = self.sample_index as f64 / self.sample_rate;
        let w1 = 2.0 * PI * self.line_freq * t;
        let w2 = 2.0 * PI * (2.0 * self.line_freq) * t;
        let refs = [w1.sin(), w1.cos(), w2.sin(), w2.cos()];
        let mu_line = 0.015;

        let mut stage1 = vec![0.0; ch];
        let mut removed_energy = 0.0;
        let mut total_energy = 1e-6;

        // 1. CleanLine + EMG / slew-pop suppression + 1 Hz HP extraction
        for c in 0..ch {
            let raw = input.get(c).copied().unwrap_or(0.0);
            let mut x = if raw.is_finite() { raw } else { 0.0 };

            if self.enable_cleanline {
                let w = &mut self.cleanline_weights[c];
                let y_hat = w[0] * refs[0] + w[1] * refs[1] + w[2] * refs[2] + w[3] * refs[3];
                let err = x - y_hat;
                for k in 0..4 {
                    w[k] = (w[k] + mu_line * err * refs[k]).clamp(-10000.0, 10000.0);
                }
                x = err;
            }

            if self.enable_emg {
                if self.sample_index > 0 {
                    let diff = x - self.prev_sample[c];
                    let abs_diff = diff.abs();
                    let limit = (self.ema_abs_diff[c] * 6.0).max(25.0);
                    if abs_diff > limit {
                        let excess = abs_diff - limit;
                        let damp = limit + excess * (limit / (limit + excess));
                        x = self.prev_sample[c] + diff.signum() * damp;
                    } else {
                        self.ema_abs_diff[c] =
                            0.992 * self.ema_abs_diff[c] + 0.008 * abs_diff.max(1.0);
                    }
                }
                self.prev_sample[c] = x;
            }

            stage1[c] = x;
            self.hp_lp_state[c] += self.hp_alpha * (x - self.hp_lp_state[c]);
            let hp_val = x - self.hp_lp_state[c];
            total_energy += hp_val * hp_val;

            // Shift sliding window and append latest sample
            let wlen = self.win_len;
            self.win_buf[c].copy_within(1..wlen, 0);
            self.win_buf[c][wlen - 1] = hp_val;
            self.raw_win_buf[c].copy_within(1..wlen, 0);
            self.raw_win_buf[c][wlen - 1] = x;
        }

        // Auto-feed calibration if ASR is enabled and not yet calibrated
        if self.enable_asr && !self.cal_ready {
            self.push_calibration(&stage1);
        }

        // 2. Periodically update ASR reconstruction matrix every hop_len samples
        self.hop_counter += 1;
        if self.enable_asr && self.cal_ready && self.hop_counter >= self.hop_len {
            self.hop_counter = 0;
            self.prev_recon_mat.copy_from_slice(&self.recon_mat);
            self.update_asr_operator();
        }

        // Crossfade smoothly between previous and current hop ASR operator
        let mut after_asr = stage1.clone();
        if self.enable_asr && self.cal_ready {
            let alpha = (self.hop_counter as f64 / self.hop_len.max(1) as f64).clamp(0.0, 1.0);
            let w_blend = 0.5 - 0.5 * (PI * alpha).cos();
            let mut sum_recon_diag = 0.0;
            for r in 0..ch {
                let coeff_diag =
                    (1.0 - w_blend) * self.prev_recon_mat[r * ch + r]
                    + w_blend * self.recon_mat[r * ch + r];
                sum_recon_diag += coeff_diag;
                let mut hp_recon = 0.0;
                for c in 0..ch {
                    let coeff =
                        (1.0 - w_blend) * self.prev_recon_mat[r * ch + c]
                        + w_blend * self.recon_mat[r * ch + c];
                    hp_recon += coeff * self.win_buf[c][self.win_len - 1];
                }
                // Preserve slow baseline only when subspace reconstruction isn't attenuating channel r
                let dc_keep = coeff_diag.clamp(0.0, 1.0);
                after_asr[r] = dc_keep * self.hp_lp_state[r] + hp_recon;
                let diff = stage1[r] - after_asr[r];
                removed_energy += diff * diff;
            }
            let _ = sum_recon_diag;
        }

        // 3. Gated Frontal / EOG Adaptive NLMS Blink Cancellation
        let mut final_out = after_asr.clone();
        if self.enable_eog && ch >= 3 {
            let ref_mask = if self.eog_ch_mask != 0 {
                self.eog_ch_mask
            } else {
                0b11 // Fp1 + Fp2 (first two frontal channels)
            };
            let mut ref_norm = 0.0;
            let mut ref_active = false;
            for r in 0..ch.min(32) {
                if (ref_mask & (1u32 << r)) != 0 {
                    let hp_r = after_asr[r] - self.hp_lp_state[r];
                    ref_norm += hp_r * hp_r;
                    if hp_r.abs() > 35.0 {
                        ref_active = true;
                    }
                }
            }
            if ref_active && ref_norm > 1.0 {
                let step = 0.035 / (ref_norm + 250.0);
                for c in 0..ch {
                    if c < 32 && (ref_mask & (1u32 << c)) != 0 {
                        continue;
                    }
                    let hp_c = after_asr[c] - self.hp_lp_state[c];
                    let mut est = 0.0;
                    for r in 0..ch.min(32) {
                        if (ref_mask & (1u32 << r)) != 0 {
                            let hp_r = after_asr[r] - self.hp_lp_state[r];
                            est += self.eog_weights[c][r] * hp_r;
                        }
                    }
                    let err = hp_c - est;
                    for r in 0..ch.min(32) {
                        if (ref_mask & (1u32 << r)) != 0 {
                            let hp_r = after_asr[r] - self.hp_lp_state[r];
                            self.eog_weights[c][r] =
                                (self.eog_weights[c][r] + step * err * hp_r).clamp(-1.2, 1.2);
                        }
                    }
                    final_out[c] -= est;
                    removed_energy += est * est;
                }
            }
        }

        self.sample_index += 1;
        for c in 0..output.len().min(ch) {
            output[c] = final_out[c];
        }
        let intensity = (removed_energy / (total_energy + removed_energy)).clamp(0.0, 1.0);
        self.last_intensity = 0.85 * self.last_intensity + 0.15 * intensity;
        self.last_intensity
    }

    fn update_asr_operator(&mut self) {
        let ch = self.channel_count;
        let wlen = self.win_len;
        let mut cov = vec![0.0; ch * ch];
        for a in 0..ch {
            for b in a..ch {
                let mut dot = 0.0;
                for t in 0..wlen {
                    dot += self.win_buf[a][t] * self.win_buf[b][t];
                }
                let v = dot / wlen as f64;
                cov[a * ch + b] = v;
                cov[b * ch + a] = v;
            }
        }

        let (evals, u_mat) = jacobi_eigen_sym(&cov, ch, 50);
        // Check each local eigenvector k against directional calibration threshold:
        // variance_k = evals[k]; limit_inv_sq = u_k^T * Q * u_k -> trivial iff evals[k] * (u_k^T Q u_k) <= 1
        let mut keep_cols: Vec<usize> = Vec::with_capacity(ch);
        for k in 0..ch {
            let mut quad_q = 0.0;
            for r in 0..ch {
                let ur = u_mat[r * ch + k];
                for c in 0..ch {
                    quad_q += ur * self.asr_q_mat[r * ch + c] * u_mat[c * ch + k];
                }
            }
            if evals[k].max(0.0) * quad_q <= 1.0 {
                keep_cols.push(k);
            }
        }

        if keep_cols.len() == ch {
            self.recon_mat = identity_matrix(ch);
            return;
        }
        if keep_cols.is_empty() {
            // Extreme full-cap artifact burst: heavily attenuate back toward quiet baseline
            self.recon_mat = vec![0.0; ch * ch];
            return;
        }

        // V_keep (ch x K), A = V_keep^T * M (K x ch)
        let k_len = keep_cols.len();
        let mut a_mat = vec![0.0; k_len * ch];
        for (ki, &col_idx) in keep_cols.iter().enumerate() {
            for mcol in 0..ch {
                let mut s = 0.0;
                for r in 0..ch {
                    s += u_mat[r * ch + col_idx] * self.asr_mixing[r * ch + mcol];
                }
                a_mat[ki * ch + mcol] = s;
            }
        }

        // Right/Moore-Penrose regularized pseudoinverse A^+ = A^T (A A^T + eps I)^{-1}
        let mut aa_t = vec![0.0; k_len * k_len];
        for i in 0..k_len {
            for j in i..k_len {
                let mut s = 0.0;
                for mcol in 0..ch {
                    s += a_mat[i * ch + mcol] * a_mat[j * ch + mcol];
                }
                aa_t[i * k_len + j] = s;
                aa_t[j * k_len + i] = s;
            }
            aa_t[i * k_len + i] += 1e-3;
        }
        let (s_evals, s_vecs) = jacobi_eigen_sym(&aa_t, k_len, 40);
        let mut aa_inv = vec![0.0; k_len * k_len];
        for i in 0..k_len {
            for j in 0..k_len {
                let mut sum = 0.0;
                for m in 0..k_len {
                    let lam = s_evals[m].max(1e-6);
                    sum += s_vecs[i * k_len + m] * s_vecs[j * k_len + m] / lam;
                }
                aa_inv[i * k_len + j] = sum;
            }
        }

        // pinv_A = A^T * aa_inv (ch x K)
        let mut pinv_a = vec![0.0; ch * k_len];
        for r in 0..ch {
            for j in 0..k_len {
                let mut sum = 0.0;
                for i in 0..k_len {
                    sum += a_mat[i * ch + r] * aa_inv[i * k_len + j];
                }
                pinv_a[r * k_len + j] = sum;
            }
        }

        // B = pinv_A * V_keep^T (ch x ch), then R = M * B (ch x ch)
        let mut b_mat = vec![0.0; ch * ch];
        for r in 0..ch {
            for c in 0..ch {
                let mut sum = 0.0;
                for (ki, &col_idx) in keep_cols.iter().enumerate() {
                    sum += pinv_a[r * k_len + ki] * u_mat[c * ch + col_idx];
                }
                b_mat[r * ch + c] = sum;
            }
        }

        let mut r_mat = vec![0.0; ch * ch];
        for r in 0..ch {
            for c in 0..ch {
                let mut sum = 0.0;
                for m in 0..ch {
                    sum += self.asr_mixing[r * ch + m] * b_mat[m * ch + c];
                }
                r_mat[r * ch + c] = sum.clamp(-2.5, 2.5);
            }
        }
        self.recon_mat = r_mat;
    }
}

fn identity_matrix(n: usize) -> Vec<f64> {
    let mut m = vec![0.0; n * n];
    for i in 0..n {
        m[i * n + i] = 1.0;
    }
    m
}

/// Classical cyclic Jacobi eigensolver for symmetric n x n matrices.
/// Returns (eigenvalues, eigenvectors row-major where column j is eigenvector j).
pub(crate) fn jacobi_eigen_sym(mat: &[f64], n: usize, max_sweeps: usize) -> (Vec<f64>, Vec<f64>) {
    let mut a = mat.to_vec();
    let mut v = identity_matrix(n);
    if n <= 1 {
        return (a, v);
    }

    for _ in 0..max_sweeps {
        let mut off_max = 0.0_f64;
        for p in 0..(n - 1) {
            for q in (p + 1)..n {
                let apq = a[p * n + q];
                off_max = off_max.max(apq.abs());
                if apq.abs() < 1e-11 {
                    continue;
                }
                let app = a[p * n + p];
                let aqq = a[q * n + q];
                let tau = (aqq - app) / (2.0 * apq);
                let t = if tau >= 0.0 {
                    1.0 / (tau + (1.0 + tau * tau).sqrt())
                } else {
                    -1.0 / (-tau + (1.0 + tau * tau).sqrt())
                };
                let c = 1.0 / (1.0 + t * t).sqrt();
                let s = t * c;

                a[p * n + p] = app - t * apq;
                a[q * n + q] = aqq + t * apq;
                a[p * n + q] = 0.0;
                a[q * n + p] = 0.0;

                for r in 0..n {
                    if r != p && r != q {
                        let arp = a[r * n + p];
                        let arq = a[r * n + q];
                        a[r * n + p] = c * arp - s * arq;
                        a[p * n + r] = a[r * n + p];
                        a[r * n + q] = s * arp + c * arq;
                        a[q * n + r] = a[r * n + q];
                    }
                    let vrp = v[r * n + p];
                    let vrq = v[r * n + q];
                    v[r * n + p] = c * vrp - s * vrq;
                    v[r * n + q] = s * vrp + c * vrq;
                }
            }
        }
        if off_max < 1e-9 {
            break;
        }
    }

    let evals = (0..n).map(|i| a[i * n + i]).collect();
    (evals, v)
}

#[no_mangle]
pub unsafe extern "C" fn ccs_cleaner_create(
    channel_count: usize,
    sample_rate: f64,
) -> *mut OnlineEegCleaner {
    Box::into_raw(Box::new(OnlineEegCleaner::new(channel_count, sample_rate)))
}

#[no_mangle]
pub unsafe extern "C" fn ccs_cleaner_set_config(
    ptr: *mut OnlineEegCleaner,
    enable_cleanline: u8,
    line_freq: f64,
    enable_asr: u8,
    asr_cutoff: f64,
    enable_eog: u8,
    enable_emg: u8,
    eog_ch_mask: u32,
) {
    if ptr.is_null() {
        return;
    }
    (*ptr).set_config(
        enable_cleanline != 0,
        line_freq,
        enable_asr != 0,
        asr_cutoff,
        enable_eog != 0,
        enable_emg != 0,
        eog_ch_mask,
    );
}

#[no_mangle]
pub unsafe extern "C" fn ccs_cleaner_calibrate_push(
    ptr: *mut OnlineEegCleaner,
    sample: *const f64,
    channel_count: usize,
) -> i32 {
    if ptr.is_null() || sample.is_null() {
        return 0;
    }
    let slice = std::slice::from_raw_parts(sample, channel_count);
    (*ptr).push_calibration(slice)
}

#[no_mangle]
pub unsafe extern "C" fn ccs_cleaner_process_sample(
    ptr: *mut OnlineEegCleaner,
    input: *const f64,
    output: *mut f64,
    channel_count: usize,
) -> f64 {
    if ptr.is_null() || input.is_null() || output.is_null() || channel_count == 0 {
        return 0.0;
    }
    let in_slice = std::slice::from_raw_parts(input, channel_count);
    let out_slice = std::slice::from_raw_parts_mut(output, channel_count);
    (*ptr).process_sample(in_slice, out_slice)
}

#[no_mangle]
pub unsafe extern "C" fn ccs_cleaner_calibration_progress(ptr: *const OnlineEegCleaner) -> i32 {
    if ptr.is_null() {
        return 0;
    }
    (*ptr).calibration_progress()
}

#[no_mangle]
pub unsafe extern "C" fn ccs_cleaner_reset(ptr: *mut OnlineEegCleaner) {
    if !ptr.is_null() {
        (*ptr).reset();
    }
}

#[no_mangle]
pub unsafe extern "C" fn ccs_cleaner_free(ptr: *mut OnlineEegCleaner) {
    if !ptr.is_null() {
        let _ = Box::from_raw(ptr);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleanline_attenuates_50hz_line_noise() {
        let mut cleaner = OnlineEegCleaner::new(2, 250.0);
        cleaner.set_config(true, 50.0, false, 15.0, false, false, 0);
        let mut out = [0.0_f64; 2];
        let mut in_pow = 0.0;
        let mut out_pow = 0.0;
        for i in 0..750 {
            let t = i as f64 / 250.0;
            let hum = 80.0 * (2.0 * PI * 50.0 * t).sin();
            let alpha = 15.0 * (2.0 * PI * 10.0 * t).sin();
            let inp = [alpha + hum, alpha + hum];
            cleaner.process_sample(&inp, &mut out);
            if i >= 500 {
                in_pow += hum * hum;
                let err = out[0] - alpha;
                out_pow += err * err;
            }
        }
        assert!(out_pow < in_pow * 0.05, "50Hz residual power was too high: {out_pow} vs {in_pow}");
    }

    #[test]
    fn asr_reconstructs_burst_after_calibration() {
        let ch = 4;
        let sr = 250.0;
        let mut cleaner = OnlineEegCleaner::new(ch, sr);
        cleaner.set_config(true, 50.0, true, 6.0, false, false, 0);

        // Feed 5s of correlated multichannel clean alpha EEG for calibration
        let mut prog = 0;
        for i in 0..1250 {
            let t = i as f64 / sr;
            let s1 = 18.0 * (2.0 * PI * 10.0 * t).sin();
            let s2 = 12.0 * (2.0 * PI * 6.0 * t).cos();
            let sample = [
                s1 + 0.3 * s2,
                0.8 * s1 + 0.5 * s2,
                -0.6 * s1 + s2,
                0.5 * s1 - 0.8 * s2,
            ];
            prog = cleaner.push_calibration(&sample);
        }
        assert_eq!(prog, 100);

        let mut out = [0.0; 4];
        let mut max_raw = 0.0_f64;
        let mut max_cleaned = 0.0_f64;
        for i in 0..600 {
            let t = i as f64 / sr;
            let clean0 = 18.0 * (2.0 * PI * 10.0 * t).sin();
            let burst = if (160..420).contains(&i) {
                450.0 * (2.0 * PI * 4.5 * t).sin()
            } else {
                0.0
            };
            let inp = [
                clean0 + burst,
                0.8 * clean0,
                -0.6 * clean0,
                0.5 * clean0,
            ];
            cleaner.process_sample(&inp, &mut out);
            if (260..410).contains(&i) {
                max_raw = max_raw.max(inp[0].abs());
                max_cleaned = max_cleaned.max(out[0].abs());
            }
        }
        assert!(max_cleaned < max_raw * 0.45, "ASR failed to suppress artifact: {max_cleaned} vs {max_raw}");
    }
}
