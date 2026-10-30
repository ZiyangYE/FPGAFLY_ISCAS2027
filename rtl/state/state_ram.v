// Hold the request-valid flag and selected output page between requests.
module state_ram #(
    parameter LANES = 24,
    ROWS = (166700 + LANES - 1) / LANES,
    ADDRESS_WIDTH = 13
) (
    input wire clk,
    input wire read_enable,
    input wire [LANES*24/9*ADDRESS_WIDTH-1:0] read_address,
    output wire [LANES*24-1:0] read_data,
    input wire write_enable,
    input wire [LANES*24/9*ADDRESS_WIDTH-1:0] write_address,
    input wire [LANES*24-1:0] write_data,
    input wire [LANES*24/9-1:0] write_bank_mask
);

    localparam PAGES = (ROWS + 2047) / 2048;
    genvar bank, page;

    generate
        for (bank = 0; bank < LANES * 24 / 9; bank = bank + 1) begin : banks
            wire [12:0] read_row = read_address[bank*ADDRESS_WIDTH+:ADDRESS_WIDTH];
            wire [12:0] write_row = write_address[bank*ADDRESS_WIDTH+:ADDRESS_WIDTH];
            (* syn_preserve=1 *) reg staged_read = 0, staged_write = 0;
            (* syn_preserve=1 *) reg [12:0] staged_read_address, staged_address;
            (* syn_preserve=1 *) reg [1:0] read_page;
            reg [8:0] staged_data;
            wire capture_read  /* synthesis syn_keep=1 */;
            wire capture_write  /* synthesis syn_keep=1 */;
            LUT2 #(
                .INIT(4'hA)
            ) read_capture (
                .I0(read_enable),
                .I1(read_row[11]),
                .F (capture_read)
            );

            LUT2 #(
                .INIT(4'h8)
            ) write_capture (
                .I0(write_enable),
                .I1(write_bank_mask[bank]),
                .F (capture_write)
            );

            always @(posedge clk) begin
                staged_read <= capture_read;
                staged_write <= capture_write;
                staged_read_address <= read_row;
                staged_address <= write_row;
                staged_data <= write_data[bank*9+:9];
                if (staged_read) read_page <= staged_read_address[12:11];
            end
            wire [PAGES*9-1:0] page_data;
            assign read_data[bank*9+:9] = page_data[read_page*9+:9];
            for (page = 0; page < PAGES; page = page + 1) begin : pages
                wire [35:0] native_data;
                wire local_read_enable  /* synthesis syn_keep=1 */;
                LUT2 #(
                    .INIT(4'h8)
                ) read_gate (
                    .I0(staged_read),
                    .I1(staged_read_address[12:11] == page),
                    .F (local_read_enable)
                );

                assign page_data[page*9+:9] = native_data[8:0];
                SDPX9B #(
                    .BIT_WIDTH_0(9),
                    .BIT_WIDTH_1(9),
                    .READ_MODE  (1'b0),
                    .BLK_SEL_0  (3'b000),
                    .BLK_SEL_1  (3'b000)
                ) memory (
                    .DO(native_data),
                    .DI({27'b0, staged_data}),
                    .BLKSELA(3'b000),
                    .BLKSELB(3'b000),
                    .ADA({staged_address[10:0], 3'b000}),
                    .ADB({staged_read_address[10:0], 3'b000}),
                    .CLKA(clk),
                    .CLKB(clk),
                    .CEA(staged_write && staged_address[12:11] == page),
                    .CEB(local_read_enable),
                    .OCE(1'b1),
                    .RESET(1'b0)
                );

            end
        end
    endgenerate

endmodule
