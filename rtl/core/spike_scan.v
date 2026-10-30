// Mark fired neurons and scan them in ID order for delayed delivery.
module spike_scan #(
    parameter N=166700
) (
    clk, rst, clear, mark_address,
    mark_capture, mark_write, scan_start, scan_load,
    scan_test, select_bit, consume, index,
    neuron, empty, selected_id
);
    input clk;
    input rst;
    input clear;
    input mark_address;
    input mark_capture;
    input mark_write;
    input scan_start;
    input scan_load;
    input scan_test;
    input select_bit;
    input consume;
    input [9:0] index;
    input [17:0] neuron;
    output empty;
    output [17:0] selected_id;

    localparam WORDS = (N + 255) / 256;
    reg [255:0] word = 0;
    reg [15:0] groups = 0;
    reg [3:0] group;
    reg [7:0] bit_index;
    reg mark_mode = 0;
    wire [255:0] data;
    wire [3:0] first_group, first_bit;
    wire [9:0] address = mark_mode ? neuron[17:8] :
        scan_start ? index : index + (scan_test && empty ? 10'd2 : 10'd1);
    wire write_enable = clear || mark_write || scan_test && empty;
    assign empty = !(|groups);
    assign selected_id = {index, bit_index};
    spike_bitmap bitmap (
        clk, address, data, write_enable,
        mark_write ? neuron[17:8] : index,
        mark_write ? word | (256'b1 << neuron[7:0]) : 256'b0
    );
    priority_encoder group_select (groups, first_group);
    priority_encoder bit_select (word[group*16+:16], first_bit);

    always @(posedge clk) begin
        if (rst) mark_mode <= 0;
        else mark_mode <= mark_address;
        if (mark_capture || scan_load || scan_test && empty && index != WORDS - 1)
            word <= data;
        else if (consume) word[bit_index] <= 0;
        if (scan_test && !empty) group <= first_group;
        if (select_bit) bit_index <= {group, first_bit};
    end

    genvar lane;
    generate
        for (lane=0; lane<16; lane=lane+1) begin : group_flags
            always @(posedge clk) begin
                if (mark_capture || scan_load || scan_test && empty && index != WORDS - 1)
                    groups[lane] <= |data[lane*16+:16];
                else if (consume && bit_index[7:4] == lane)
                    groups[lane] <= |(word[lane*16+:16] & ~(16'b1 << bit_index[3:0]));
            end
        end
    endgenerate
endmodule
