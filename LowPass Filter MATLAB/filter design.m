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

% 3. Analyze the filter
fvtool(lpFilt); % This will show you the 80dB drop and the sharp transition

% 4. Verify the number of taps and print the values of the coefficients
fprintf('Number of taps in the design: %d\n', length(b));
fprintf("The value of the co-efficients are as follows:\n");
fprintf("%f\n", b);
% 5. Export to a file named 'filter_taps.csv'
writematrix(b, 'filter_taps.csv');
