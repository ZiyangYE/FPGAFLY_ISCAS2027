// Track the nineteen delay slots and pack four descriptors per DDR line.
module delay_queue #(
    parameter START_T=2000
) (
    input clk, rst, abort, start, step, advance,
    input clear_pack, partial_load, append, flush, drained,
    input [255:0] read_data,
    input [63:0] entry,
    input init_valid,
    input [4:0] init_slot,
    input [17:0] init_count,
    input [21:0] initial_pending,
    input [17:0] initial_peak,
    output reg [4:0] current_slot = START_T % 19,
    output reg [17:0] current_count, future_count,
    output [31:0] next_address,
    output reg [31:0] write_address,
    output reg [255:0] packed_data = 0,
    output reg [21:0] pending_events = 0,
    output reg [21:0] pending_peak = 0,
    output reg [17:0] queue_peak = 0
);
    (* syn_ramstyle="registers" *) reg [17:0] count[0:18];
    reg [4:0] future_slot = (START_T + 18) % 19;
    reg write_enable = 0;
    reg [4:0] write_slot;
    reg [17:0] write_count;
    wire [6:0] slot_scaled = {2'b0, future_slot} + {1'b0, future_slot, 1'b0};
    assign next_address = {4'h2, slot_scaled, future_count[17:2], 5'b0};

    always @(posedge clk) begin
        write_enable <= !rst && (flush || drained);
        write_slot <= flush ? future_slot : current_slot;
        write_count <= flush ? future_count : 18'd0;
        if (init_valid) count[init_slot] <= init_count;
        else if (write_enable) count[write_slot] <= write_count;
    end

    always @(posedge clk) begin
        if (!rst && !abort) begin
            if (start) begin
                current_slot <= START_T % 19;
                future_slot <= (START_T + 18) % 19;
                pending_events <= initial_pending;
                pending_peak <= initial_pending;
                queue_peak <= initial_peak;
            end else begin
                if (pending_events > pending_peak) pending_peak <= pending_events;
                if (step) begin
                    current_count <= count[current_slot];
                    future_count <= count[future_slot];
                end
                if (advance) begin
                    current_slot <= current_slot == 18 ? 5'd0 : current_slot + 1'b1;
                    future_slot <= future_slot == 18 ? 5'd0 : future_slot + 1'b1;
                end
                if (clear_pack) packed_data <= 0;
                if (partial_load) packed_data <= read_data;
                if (append) begin
                    packed_data[future_count[1:0]*64+:64] <= entry;
                    write_address <= next_address;
                    future_count <= future_count + 1'b1;
                    pending_events <= pending_events + 1'b1;
                end
                if (flush && future_count > queue_peak) queue_peak <= future_count;
                if (drained) pending_events <= pending_events - current_count;
            end
        end
    end
endmodule
