// The harness counts clock cycles without using the Verilator time scheduler. This
// callback supplies assertion timestamps only; DDR timing uses the cycle counter.
double sc_time_stamp() { return 0.0; }
