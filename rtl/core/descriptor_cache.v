// Cache descriptor and coefficient lines; keep each word write enable local.
module descriptor_cache (
    clk, rst, source, original_id,
    coeff_index, ordered_load, descriptor_load, coefficient_load,
    memory_result, descriptor_result, ordered_result, rd_data,
    bus_result, descriptor_match, ordered_match, coefficient_match,
    coefficient_word
);
    input clk;
    input rst;
    input [17:0] source;
    input [17:0] original_id;
    input [13:0] coeff_index;
    input ordered_load;
    input descriptor_load;
    input coefficient_load;
    input memory_result;
    input descriptor_result;
    input ordered_result;
    input [255:0] rd_data;
    output [255:0] bus_result;
    output descriptor_match;
    output ordered_match;
    output coefficient_match;
    output [31:0] coefficient_word;

    reg descriptor_cached = 0, coefficient_cached = 0;
    reg [16:0] descriptor_tag;
    reg [10:0] coefficient_tag;
    reg [255:0] descriptor_cache, coefficient_cache;
    reg ordered_cached = 0;
    reg [15:0] ordered_tag;
    reg [255:0] ordered_cache;

    always @(posedge clk) begin
        if (rst) ordered_cached <= 0;
        else if (ordered_load) begin
            ordered_cached <= 1;
            ordered_tag <= original_id[17:2];
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            descriptor_cached <= 0;
            coefficient_cached <= 0;
        end else begin
            if (descriptor_load) begin
                descriptor_cached <= 1;
                descriptor_tag <= source[17:1];
            end
            if (coefficient_load) begin
                coefficient_cached <= 1;
                coefficient_tag <= coeff_index[13:3];
            end
        end
    end
    reg [255:0] bus_result;
    wire [255:0] next_bus_result = descriptor_result ? descriptor_cache :
        ordered_result ? ordered_cache : rd_data;
    genvar cache_word;

    generate
        for (cache_word = 0; cache_word < 8; cache_word = cache_word + 1) begin : cache_control
            wire ordered_enable  /* synthesis syn_keep=1 */;
            wire descriptor_enable  /* synthesis syn_keep=1 */;
            wire coefficient_enable  /* synthesis syn_keep=1 */;
            wire bus_enable  /* synthesis syn_keep=1 */;
            assign ordered_enable = !rst && (ordered_load);

            assign descriptor_enable = !rst && (descriptor_load);

            assign coefficient_enable = !rst && (coefficient_load);

            assign bus_enable = !rst && (memory_result || descriptor_result || ordered_result);

            always @(posedge clk) begin
                if (ordered_enable)
                    ordered_cache[cache_word*32+:32] <= bus_result[cache_word*32+:32];
                if (descriptor_enable)
                    descriptor_cache[cache_word*32+:32] <= bus_result[cache_word*32+:32];
                if (coefficient_enable)
                    coefficient_cache[cache_word*32+:32] <= bus_result[cache_word*32+:32];
                if (bus_enable) bus_result[cache_word*32+:32] <= next_bus_result[cache_word*32+:32];
            end
        end
    endgenerate
    assign descriptor_match = descriptor_cached && descriptor_tag == source[17:1];
    assign ordered_match = ordered_cached && ordered_tag == original_id[17:2];
    assign coefficient_match = coefficient_cached && coefficient_tag == coeff_index[13:3];
    assign coefficient_word = coefficient_cache[coeff_index[2:0]*32+:32];
endmodule
