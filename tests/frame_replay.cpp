#include "Vframe_sim.h"

#include "verilated.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
using namespace std;
constexpr unsigned DDR_PREFETCH = 64;
constexpr unsigned STATE_LANES = 42;
vector<uint8_t> read_file(const string &path) {
    ifstream f(path, ios::binary | ios::ate);
    if (!f)
        throw runtime_error(path);
    vector<uint8_t> v(size_t(f.tellg()));
    f.seekg(0);
    f.read((char *)v.data(), v.size());
    return v;
}
vector<uint8_t> read_range(const string &path, size_t offset, size_t count) {
    ifstream f(path, ios::binary);
    if (!f) throw runtime_error(path);
    f.seekg(offset);
    vector<uint8_t> data(count);
    f.read((char *)data.data(), count);
    if (!f) throw runtime_error("Reference data truncated: " + path);
    return data;
}
uint64_t u64(const vector<uint8_t> &v, size_t off) {
    uint64_t x;
    memcpy(&x, v.data() + off, 8);
    return x;
}
struct Sim {
    Vframe_sim top;
    map<uint32_t, vector<uint8_t>> mem;
    struct Read {
        uint64_t due;
        array<uint32_t, 8> data;
    };
    deque<Read> reads;
    uint64_t tick = 0, latency, read_commands = 0, write_commands = 0;
    double interval, random_interval, next_issue = 0;
    uint32_t previous_address = 0;
    bool previous_read = false;
    unsigned seq = 0, peak = 0, n;
    vector<unsigned> spikes;
    array<uint64_t, 4> section_cycles{};
    Sim(unsigned nn, uint64_t l, double i, double ri)
        : latency(l), interval(i), random_interval(ri), n(nn), spikes(nn) {}
    uint8_t *pointer(uint32_t address) {
        auto it = mem.upper_bound(address);
        if (it == mem.begin())
            throw runtime_error("unmapped DDR read");
        --it;
        size_t off = address - it->first;
        if (off + 32 > it->second.size())
            throw runtime_error("DDR bounds address=" + to_string(address));
        return it->second.data() + off;
    }
    uint64_t ui_tick = 0, subtick = 0;
    void cycle() {
        top.clk = 0;
        top.cmd_ready = tick >= uint64_t(ceil(next_issue));
        top.wr_ready = top.cmd_ready;
        top.rd_valid = !reads.empty() && reads.front().due <= tick;
        if (top.rd_valid) {
            for (int j = 0; j < 8; j++)
                top.rd_data[j] = reads.front().data[j];
            reads.pop_front();
        }
        top.eval();
        if (top.busy)
            section_cycles[top.trace_section]++;
        if (top.cmd_en) {
            if (!top.cmd_ready || (top.wr_en && !top.wr_ready))
                throw runtime_error("DDR handshake");
            uint32_t address = top.addr << 2;
            if (address & 31)
                throw runtime_error("DDR alignment");
            auto data = pointer(address);
            if (top.cmd == 0) {
                if (!top.wr_en)
                    throw runtime_error("missing DDR write data");
                for (int b = 0; b < 32; b++)
                    if (!(top.wr_mask & (1u << b)))
                        data[b] = uint8_t(top.wr_data[b / 4] >> ((b % 4) * 8));
                write_commands++;
            } else {
                Read r;
                r.due = tick + latency;
                memcpy(r.data.data(), data, 32);
                reads.push_back(r);
                read_commands++;
                peak = max(peak, unsigned(reads.size()));
                if (reads.size() > DDR_PREFETCH + 1)
                    throw runtime_error("unbounded DDR requests");
            }
            double service = top.cmd != 0 && (!previous_read || address != previous_address + 32)
                                 ? random_interval
                                 : interval;
            next_issue = max(next_issue, double(tick) - 0.999999) + service;
            previous_address = address;
            previous_read = top.cmd != 0;
        }
        if (top.trace_fire_valid)
            for (unsigned j = 0; j < STATE_LANES; j++)
                if (top.trace_fire_mask & (uint64_t(1) << j)) {
                    unsigned id = top.trace_fire_row * STATE_LANES + j;
                    if (id < n)
                        spikes[id]++;
                }
        top.clk = 1;
        top.eval();
        tick++;
        if (Verilated::gotFinish())
            throw runtime_error("RTL finish/assertion");
    }
    array<uint32_t, 16> command(unsigned op, unsigned word2 = 0) {
        for (int j = 0; j < 16; j++)
            top.packet[j] = 0;
        top.packet[0] = 0x44445233;
        top.packet[1] = (++seq << 8) | op;
        top.packet[2] = word2;
        top.request = !top.request;
        uint64_t deadline = tick + 100000000;
        do {
            cycle();
            if (tick > deadline)
                throw runtime_error("RTL command timeout op=" + to_string(op));
        } while (top.acknowledge != top.request);
        array<uint32_t, 16> response;
        for (int j = 0; j < 16; j++)
            response[j] = top.response[j];
        if (response[2] & 24)
            throw runtime_error(
                "RTL failed flags=" + to_string(response[2]) + " step=" + to_string(response[4]) +
                " spikes=" + to_string(response[5]) + " edges=" + to_string(response[6]) +
                " pool_peak=" + to_string(response[7]) +
                " cycles=" + to_string(response[9] | uint64_t(response[10]) << 32));
        return response;
    }
    void load(uint32_t address, const string &file) {
        auto v = read_file(file);
        v.resize((v.size() + 31) / 32 * 32);
        mem[address] = move(v);
    }
};
int main(int argc, char **argv) {
    try {
        if (argc != 8)
            throw runtime_error("root count latency interval reference random_interval first_reference");
        string root = argv[1], images = root + "/data/model",
               ref = root + "/data/reference";
        if (const char *image_path = getenv("THEFLY_IMAGES"))
            images = image_path;
        string input_path = root + "/data/input.bin";
        if (const char *path = getenv("THEFLY_INPUT")) input_path = path;
        const unsigned pixels = 256;
        const unsigned opcode = 35;
        ref = argv[5];
        auto row_bytes = read_file(ref + "/rows.bin");
        unsigned frames = stoul(argv[2]), first = stoul(argv[7]);
        if (row_bytes.size() < (first + frames) * 4)
            throw runtime_error("missing reference rows");
        unsigned n = 166700;
        Sim sim(n, stoull(argv[3]), stod(argv[4]), stod(argv[6]));
        for (auto x : vector<pair<uint32_t, string>>{{0, "graph_edges.u64"},
                                                     {0x10000000, "source_descriptor.u128"},
                                                     {0x10400000, "readout_coeff.u32"},
                                                     {0x10610000, "readout_bias.i64"},
                                                     {0x10800000, "ordered_descriptor.u64"},
                                                     {0x10980000, "retina_pulses_l42.u32"}})
            sim.load(x.first, images + "/" + x.second);
        sim.load(0x18000000, ref + "/warm.u64");
        sim.load(0x1a000000, ref + "/warm_queue.bin");
        sim.mem[0x10990000].resize(32768);
        sim.mem[0x10700000].resize(1024);
        for (unsigned q = 0; q < 19; q++)
            sim.mem[0x20000000 + q * 0x600000].resize((n * 8 + 31) / 32 * 32);
        sim.top.request = 0;
        sim.top.rst = 1;
        sim.top.calibrated = 1;
        for (int i = 0; i < 8; i++)
            sim.cycle();
        sim.top.rst = 0;
        for (unsigned frame = 0; frame < frames; frame++) {
            fill(sim.spikes.begin(), sim.spikes.end(), 0);
            sim.read_commands = sim.write_commands = 0;
            sim.peak = 0;
            sim.section_cycles.fill(0);
            ifstream input(input_path, ios::binary);
            unsigned reference_index = first + frame;
            uint32_t row_id;
            memcpy(&row_id, row_bytes.data() + reference_index * 4, 4);
            input.seekg(row_id * pixels);
            input.read((char *)sim.mem[0x10700000].data(), pixels);
            if (!input) throw runtime_error("Input image truncated");
            auto expected = read_range(ref + "/states.u64", size_t(reference_index) * n * 8, size_t(n) * 8);
            auto scores = read_file(ref + "/scores.i64"),
                 stats = read_file(ref + "/stats.u64");
            uint64_t expected_spikes = u64(stats, (reference_index * 10 + 1) * 8),
                     expected_edges = u64(stats, (reference_index * 10 + 5) * 8);
            auto response = sim.command(getenv("THEFLY_CONTINUOUS") && frame ? 36 : opcode);
            if (response[4] != 2999) throw runtime_error("Wrong final timestep");
            uint64_t cycles = response[9] | uint64_t(response[10]) << 32;
            auto sections = sim.section_cycles;
            cout << "frame " << frame << " computation complete: " << cycles
                 << " cycles, checking states" << endl;
            if (response[5] != expected_spikes || response[6] != expected_edges)
                throw runtime_error("counters got " + to_string(response[5]) + "/" +
                                    to_string(response[6]) + " expected " +
                                    to_string(expected_spikes) + "/" + to_string(expected_edges));
            uint64_t read_commands = sim.read_commands, write_commands = sim.write_commands;
            unsigned peak = sim.peak;
            for (unsigned page = 0; page < 3; page++) {
                auto r = sim.command(33, page);
                for (unsigned j = 0; j < 4 && page * 4 + j < 10; j++) {
                    unsigned off = (page * 4 + j) * 8;
                    off += reference_index * 80;
                    uint64_t value = r[8 + j * 2] | uint64_t(r[9 + j * 2]) << 32;
                    if (value != u64(scores, off))
                        throw runtime_error("score mismatch class=" + to_string(page * 4 + j));
                }
            }
            for (unsigned id = 0; id < n; id++) {
                auto r = sim.command(34, id);
                uint64_t value =
                    (r[8] | uint64_t(r[9] & 511) << 32) | (uint64_t(sim.spikes[id]) << 41);
                if (value != u64(expected, id * 8))
                    throw runtime_error("state mismatch neuron=" + to_string(id) +
                                        " got=" + to_string(value) +
                                        " expected=" + to_string(u64(expected, id * 8)));
            }
            cout << "{\"frame\":" << frame << ",\"cycles\":" << cycles
                 << ",\"seconds_at_80mhz\":" << double(cycles) / 8e7
                 << ",\"spikes\":" << response[5] << ",\"edges\":" << response[6]
                 << ",\"exception_peak\":" << response[7] << ",\"read_commands\":" << read_commands
                 << ",\"write_commands\":" << write_commands << ",\"peak_outstanding\":" << peak
                 << ",\"pending_peak\":" << response[11] << ",\"queue_peak\":" << response[12]
                 << ",\"pending_final\":" << response[14]
                 << ",\"fire_queue_peak\":" << (response[3] >> 16)
                 << ",\"init_cycles\":" << sections[0] << ",\"dense_cycles\":" << sections[1]
                 << ",\"scan_cycles\":" << sections[2] << ",\"event_cycles\":" << sections[3]
                 << ",\"all_states_counts_scores_exact\":true}" << endl;
        }
        return 0;
    } catch (const exception &e) {
        cerr << "FAIL " << e.what() << endl;
        return 1;
    }
}
