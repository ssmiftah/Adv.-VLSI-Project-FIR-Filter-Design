% Specifications
fs = 2; % Working in normalized frequency (Nyquist = 1, which is pi rad/sample)
f_pass = 0.2;   % Passband edge (0.2 * pi)
f_stop = 0.23;  % Stopband edge (0.23 * pi)
attenuation = 80; % Desired stopband attenuation in dB

% 1. Design using the Filter Designer (Equiripple method)
% We specify the order as 99 to get exactly 100 taps.
lpFilt = designfilt('lowpassfir', 'FilterOrder', 99, ...
    'PassbandFrequency', f_pass, 'StopbandFrequency', f_stop, ...
    'StopbandAttenuation', attenuation, 'SampleRate', fs);

% 2. Extract the 100 coefficients (taps)
b = lpFilt.Coefficients;

% 3. Quantize to Q1.15 (matching hardware ROM: 16-bit signed, scale = 2^15)
num_frac_bits = 15;
b_q_int = round(b * 2^num_frac_bits);                 % integer values stored in ROM
b_q_int = max(min(b_q_int, 2^num_frac_bits - 1), ...
              -2^num_frac_bits);                       % saturate to signed 16-bit range
b_q = b_q_int / 2^num_frac_bits;                      % back to floating-point

% 4. Compute frequency responses
[H_ideal, w] = freqz(b,   1, 2048, fs);
[H_quant, ~] = freqz(b_q, 1, 2048, fs);

% 5. Plot magnitude response comparison
figure('Name', 'Ideal vs Quantized (Q1.15) Frequency Response');

subplot(2,1,1);
plot(w, 20*log10(abs(H_ideal)), 'b', 'LineWidth', 1.2); hold on;
plot(w, 20*log10(abs(H_quant)), 'r--', 'LineWidth', 1.2);
xlabel('Normalized Frequency (\times\pi rad/sample)');
ylabel('Magnitude (dB)');
title('Magnitude Response');
legend('Ideal (float64)', 'Quantized (Q1.15)', 'Location', 'southwest');
grid on;
ylim([-120 5]);
xline(f_pass, 'g--', 'Passband');
xline(f_stop, 'm--', 'Stopband');

subplot(2,1,2);
plot(w, 20*log10(abs(H_ideal - H_quant)), 'k', 'LineWidth', 1);
xlabel('Normalized Frequency (\times\pi rad/sample)');
ylabel('Error Magnitude (dB)');
title('Quantization Error: |H_{ideal} - H_{quantized}|');
grid on;

% 6. Also open the Filter Visualization Tool for the ideal design
fvtool(lpFilt);

% 7. Verify the number of taps and print coefficients
fprintf('Number of taps in the design: %d\n', length(b));
fprintf('\nIdeal vs Quantized coefficients:\n');
fprintf('  Index   Ideal          Quantized (Q1.15)   ROM integer\n');
for i = 1:length(b)
    fprintf('  %3d    %+12.8f   %+12.8f        %6d\n', ...
            i-1, b(i), b_q(i), b_q_int(i));
end

% 8. Export both coefficient sets
writematrix(b,   'filter_taps.csv');
writematrix(b_q, 'filter_taps_quantized.csv');