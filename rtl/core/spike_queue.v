// Use 18-bit RAM banks; 36-bit mode costs extra RAM on device revision B.
module spike_queue #(
    parameter WIDTH = 54,
    BANKS = (WIDTH + 17) / 18
) (
    input wire clk,
    input wire write_enable,
    input wire [5:0] write_address,
    input wire [WIDTH-1:0] write_data,
    input wire read_enable,
    input wire [5:0] read_address,
    output wire [WIDTH-1:0] read_data
);

    wire [BANKS*18-1:0] padded_write = {{(BANKS * 18 - WIDTH) {1'b0}}, write_data};
    wire [BANKS*18-1:0] padded_read;
    assign read_data = padded_read[WIDTH-1:0];
    genvar bank;

    generate
        for (bank = 0; bank < BANKS; bank = bank + 1) begin : banks
            wire [35:0] native_data;
            assign padded_read[bank*18+:18] = native_data[17:0];
            SDPX9B #(
                .BIT_WIDTH_0(18),
                .BIT_WIDTH_1(18),
                .READ_MODE  (1'b0),
                .BLK_SEL_0  (3'b000),
                .BLK_SEL_1  (3'b000)
            ) memory (
                .DO(native_data),
                .DI({18'b0, padded_write[bank*18+:18]}),
                .BLKSELA(3'b000),
                .BLKSELB(3'b000),
                .ADA({4'b0, write_address, 4'b0011}),
                .ADB({4'b0, read_address, 4'b0}),
                .CLKA(clk),
                .CLKB(clk),
                .CEA(write_enable),
                .CEB(read_enable),
                .OCE(1'b1),
                .RESET(1'b0)
            );

        end
    endgenerate

endmodule
