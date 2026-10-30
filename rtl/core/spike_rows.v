// Buffer spike masks from completed rows while descriptors are being read.
module spike_rows #(
    parameter LANES=42
) (
    clk, rst, start, pop_enable,
    fire_valid, fire_row, fires, fire_ready,
    fire_pop, queued_fire_data, committed, fire_queue_peak
);
    input clk;
    input rst;
    input start;
    input pop_enable;
    input fire_valid;
    input [12:0] fire_row;
    input [LANES-1:0] fires;
    output fire_ready;
    output fire_pop;
    output [LANES+11:0] queued_fire_data;
    output [12:0] committed;
    output [6:0] fire_queue_peak;

    reg [12:0] committed = 0;
    wire [LANES+11:0] queued_fire_data;
    reg [5:0] fire_head = 0, fire_tail = 0;
    reg [6:0] fire_count = 0, fire_queue_peak = 0;
    wire fire_pop = pop_enable && fire_count != 0;
    wire trace_fire_valid = fire_valid && fire_ready;
    wire fire_push = trace_fire_valid && (|fires);
    assign fire_ready = fire_count < 64;
    spike_queue #(
        .WIDTH(LANES + 12)
    ) fire_queue_memory (
        clk,
        fire_push,
        fire_tail,
        {fire_row[11:0], fires},
        fire_pop,
        fire_head,
        queued_fire_data
    );

    // Queue spike IDs; write neuron state back to its existing RAM row.
    always @(posedge clk) begin
        if (rst || start) begin
            committed <= 0;
            fire_count <= 0;
            fire_head <= 0;
            fire_tail <= 0;
        end else begin
            if (trace_fire_valid) committed <= committed + 1'b1;
            if (fire_push) fire_tail <= fire_tail + 1'b1;
            if (fire_pop) fire_head <= fire_head + 1'b1;
            case ({fire_push, fire_pop})
                2'b10: fire_count <= fire_count + 1'b1;
                2'b01: fire_count <= fire_count - 1'b1;
            endcase
        end
        if (rst) fire_queue_peak <= 0;
        else if (fire_push && !fire_pop && fire_count >= fire_queue_peak)
            fire_queue_peak <= fire_count + 1'b1;
    end
endmodule
