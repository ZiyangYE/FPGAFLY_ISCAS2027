// Sample the registered GW_JTAG outputs on board_clk.
// Hold data until the DDR side acknowledges it. Keep overrun set after a lost word.
module bulk_receiver (
    input wire clk,
    input wire jtck,
    input wire jtdi,
    input wire shift_capture,
    input wire select_bulk,
    input wire acknowledge,
    output reg request = 0,
    output reg [255:0] data = 0,
    output reg overrun = 0
);

    (* syn_preserve=1 *) reg [3:0] tck_sync = 0;
    (* syn_preserve=1 *) reg [1:0] tdi_sync = 0, sc_sync = 0, sel_sync = 0, ack_sync = 0;
    reg previous = 0;
    reg [7:0] bits = 0;
    reg [255:0] shift_reg = 0;

    always @(posedge clk) begin
        tck_sync <= {tck_sync[2:0], jtck};
        tdi_sync <= {tdi_sync[0], jtdi};
        sc_sync <= {sc_sync[0], shift_capture};
        sel_sync <= {sel_sync[0], select_bulk};
        ack_sync <= {ack_sync[0], acknowledge};
        if (tck_sync[2] && !tck_sync[3]) begin
            previous <= sc_sync[1] && sel_sync[1];
            if (sc_sync[1] && sel_sync[1]) begin
                if (!previous) begin
                    bits <= 0;
                    overrun <= 0;
                end else begin
                    shift_reg <= {tdi_sync[1], shift_reg[255:1]};
                    bits <= bits + 1'b1;
                    if (bits == 255) begin
                        if (request == ack_sync[1]) begin
                            data <= {tdi_sync[1], shift_reg[255:1]};
                            request <= ~request;
                        end else overrun <= 1;
                    end
                end
            end
        end
    end

endmodule
