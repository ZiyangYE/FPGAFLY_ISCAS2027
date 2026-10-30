// Store 652 bitmap words across fifteen 1024x18 RAMs. Pad the unused upper bits.
module spike_bitmap (
    input wire clk,
    input wire [9:0] read_address,
    output wire [255:0] read_data,
    input wire write_enable,
    input wire [9:0] write_address,
    input wire [255:0] write_data
);

    wire [269:0] padded_write = {14'b0, write_data};
    wire [269:0] padded_read;
    assign read_data = padded_read[255:0];
    genvar bank;

    generate
        for (bank = 0; bank < 15; bank = bank + 1) begin : banks
            wire [35:0] native_data;
            assign padded_read[bank*18+:18] = native_data[17:0];
            SDPX9B #(
                .BIT_WIDTH_0(18),
                .BIT_WIDTH_1(18),
                .READ_MODE  (1'b0),
                .BLK_SEL_0  (3'b0),
                .BLK_SEL_1  (3'b0)
            ) memory (
                .DO(native_data),
                .DI({18'b0, padded_write[bank*18+:18]}),
                .BLKSELA(3'b0),
                .BLKSELB(3'b0),
                .ADA({write_address, 4'b0011}),
                .ADB({read_address, 4'b0}),
                .CLKA(clk),
                .CLKB(clk),
                .CEA(write_enable),
                .CEB(1'b1),
                .OCE(1'b1),
                .RESET(1'b0)
            );

        end
    endgenerate

endmodule
