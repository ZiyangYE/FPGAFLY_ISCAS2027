module state_array #(
    parameter LANES = 42,
    ROWS = (166700 + LANES - 1) / LANES
) (
    input wire clk,
    input wire rst,
    input wire [1:0] phase,
    input wire raw_read,
    input wire raw_write,
    input wire [12:0] raw_address,
    input wire [LANES*24-1:0] raw_data,
    output wire [LANES*24-1:0] read_data,
    input wire dense_valid,
    output wire dense_ready,
    input wire [12:0] dense_row,
    input wire [LANES*18-1:0] dense_drive,
    output wire fire_valid,
    input wire fire_ready,
    output wire [12:0] fire_row,
    output wire [LANES-1:0] fire,
    output wire dense_failed,
    input wire event_valid,
    output wire event_ready,
    input wire [12:0] event_row,
    input wire [6:0] event_lane,
    input wire signed [17:0] event_weight,
    output wire event_done,
    output wire event_failed
);

    localparam TILES = 7;
    localparam LOCAL_LANES = 6;
    wire accept_dense;
    wire [TILES-1:0] queue_reset;
    wire reset_releasing =  |queue_reset;
    wire [TILES-1:0] input_ready, output_valid;
    wire [TILES-1:0] tile_failed, tile_event_ready, tile_event_done, tile_event_failed;
    wire [TILES*19-1:0] output_records;
    assign dense_ready = phase == 1 && !rst && !reset_releasing && !dense_failed && (&input_ready);
    assign accept_dense = dense_valid && dense_ready;
    assign fire_valid = phase == 1 && !rst && !reset_releasing && (&output_valid);
    assign fire_row = output_records[6+:13];
    assign dense_failed =  |tile_failed;
    // Buffer simultaneous tile replies; the core accepts one completion per clock.
    reg [3:0] completed_events = 0;
    wire [3:0] new_completions = {3'b0,tile_event_done[0]}+{3'b0,tile_event_done[1]}+
        {3'b0,tile_event_done[2]}+{3'b0,tile_event_done[3]}+{3'b0,tile_event_done[4]}+
        {3'b0,tile_event_done[5]}+{3'b0,tile_event_done[6]};
    assign event_done = completed_events != 0;

    always @(posedge clk) begin
        if (rst) completed_events <= 0;
        else completed_events <= completed_events + new_completions - {3'b0, event_done};
    end
    assign event_failed =  |tile_event_failed;

    wire [TILES-1:0] event_selected;
    wire [TILES-1:0] input_selected;
    wire [TILES*3-1:0] input_lanes;
    wire [2:0] input_lane = input_lanes[2:0] | input_lanes[5:3] |
        input_lanes[8:6] | input_lanes[11:9] | input_lanes[14:12] |
        input_lanes[17:15] | input_lanes[20:18];
    wire routed_valid, routed_ready, queue_ready;
    wire [40:0] routed_record;
    wire [12:0] routed_row = routed_record[40:28];
    wire [2:0] routed_lane = routed_record[20:18];
    wire [17:0] routed_weight = routed_record[17:0];
    assign event_selected = routed_record[27:21];
    elastic_fifo #(
        .WIDTH(41),
        .AW(2)
    ) events (
        clk,
        rst,
        event_valid && phase == 2,
        queue_ready,
        {event_row, input_selected, input_lane, event_weight},
        routed_valid,
        routed_ready,
        routed_record
    );

    assign event_ready = phase == 2 && queue_ready;
    assign routed_ready = phase == 2 &&  |(event_selected & tile_event_ready);
    genvar t;

    generate
        for (t = 0; t < TILES; t = t + 1) begin : tiles
            (* syn_preserve=1 *) reg local_reset = 1;

            always @(posedge clk) local_reset <= rst;
            assign queue_reset[t] = local_reset;
            (* syn_preserve=1 *) reg [1:0] tile_phase = 0;

            always @(posedge clk) begin
                if (rst) tile_phase <= 0;
                else tile_phase <= phase;
            end
            wire input_valid, input_take;
            wire [120:0] input_record;
            wire tile_fire_valid, tile_fire_ready;
            wire [12:0] tile_fire_row;
            wire [ 5:0] tile_fires;
            elastic_fifo #(
                .WIDTH(121),
                .AW(1)
            ) requests (
                clk,
                local_reset,
                accept_dense,
                input_ready[t],
                {dense_row, dense_drive[t*108+:108]},
                input_valid,
                input_take,
                input_record
            );

            elastic_fifo #(
                .WIDTH(19),
                .AW(2)
            ) completions (
                clk,
                local_reset,
                tile_fire_valid,
                tile_fire_ready,
                {tile_fire_row, tile_fires},
                output_valid[t],
                fire_valid && fire_ready,
                output_records[t*19+:19]
            );

            assign fire[t*6+:6] = output_records[t*19+:6];
            assign input_selected[t] = event_lane >= t * 6 && event_lane < t * 6 + 6;
            localparam FIRST_LANE = t * 6;
            wire [6:0] lane_difference = event_lane - FIRST_LANE[6:0];
            assign input_lanes[t*3+:3] = input_selected[t] ? lane_difference[2:0] : 3'b0;
            wire [6:0] local_event_lane = {4'b0, routed_lane};

            state_tile #(
                .LANES(6),
                .ROWS (ROWS)
            ) engine (
                .clk(clk),
                .rst(rst),
                .phase(tile_phase),
                .raw_read(raw_read),
                .raw_write(raw_write),
                .raw_address(raw_address),
                .raw_data(raw_data[t*144+:144]),
                .read_data(read_data[t*144+:144]),
                .dense_valid(input_valid),
                .dense_ready(input_take),
                .dense_row(input_record[108+:13]),
                .dense_drive(input_record[0+:108]),
                .fire_valid(tile_fire_valid),
                .fire_ready(tile_fire_ready),
                .fire_row(tile_fire_row),
                .fire(tile_fires),
                .dense_failed(tile_failed[t]),
                .event_valid(routed_valid && event_selected[t]),
                .event_ready(tile_event_ready[t]),
                .event_row(routed_row),
                .event_lane(local_event_lane),
                .event_weight(routed_weight),
                .event_done(tile_event_done[t]),
                .event_failed(tile_event_failed[t])
            );

            // synthesis translate_off
            always @(negedge clk)
                if (!rst && fire_valid && output_records[t*19+6+:13] !== fire_row)
                    $fatal(1, "Tile completion rows diverged");
            // synthesis translate_on
        end
    endgenerate

    // synthesis translate_off
    initial if (LANES != 42) $fatal(1, "Local tile engine requires 42 lanes");
    integer idle_cycles = 0;

    always @(posedge clk) begin
        if (rst || phase == 0 || (!dense_valid && !event_valid) ||
            accept_dense || (fire_valid && fire_ready) || event_done)
            idle_cycles <= 0;
        else idle_cycles <= idle_cycles + 1;
        if (idle_cycles == 100000) begin
            $display("APPROX STALL phase=%d", phase);
            $fatal(1, "Local engine made no progress");
        end
    end
    // synthesis translate_on

endmodule
