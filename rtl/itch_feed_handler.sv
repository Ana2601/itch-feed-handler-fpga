// Low-latency NASDAQ ITCH 5.0 feed handler:
//   10GbE AXI-Stream (64b @ 156.25 MHz) -> filter + realign + decode -> order book -> BBO updates
//
// Latency: the beat carrying a message's last byte is written into the realignment
// buffer on edge 0, the message is framed/decoded on edge 1, the book and the BBO
// output register update on edge 2, and a downstream flop captures the BBO on
// edge 3 -> 3 cycles = 19.2 ns at 156.25 MHz (measured by tb/tb_feed.sv).
module itch_feed_handler #(
    parameter integer NSYM  = 4,
    parameter integer NLVL  = 16,
    parameter integer TBITS = 10
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] cfg_udp_port,

    input  wire [63:0] s_tdata,
    input  wire [7:0]  s_tkeep,
    input  wire        s_tvalid,
    input  wire        s_tlast,
    output wire        s_tready,

    output wire        bbo_valid,
    output wire [15:0] bbo_locate,
    output wire        bbo_side,
    output wire [31:0] bbo_price,
    output wire [31:0] bbo_qty,
    output wire [31:0] bbo_msg_idx,

    output wire [31:0] stat_frames_ok,
    output wire [31:0] stat_frames_dropped,
    output wire [3:0]  err_flags        // {malformed, overflow, collision, book}
);
    wire        m_valid, m_ready, m_side;
    wire [7:0]  m_type;
    wire [15:0] m_locate;
    wire [63:0] m_ref, m_newref;
    wire [31:0] m_shares, m_price, m_idx;
    wire        e_mal, e_ovf, e_col, e_book;

    itch_parser u_parser (
        .clk(clk), .rst_n(rst_n), .cfg_udp_port(cfg_udp_port),
        .s_tdata(s_tdata), .s_tkeep(s_tkeep), .s_tvalid(s_tvalid), .s_tlast(s_tlast), .s_tready(s_tready),
        .m_valid(m_valid), .m_ready(m_ready), .m_type(m_type), .m_locate(m_locate), .m_ref(m_ref),
        .m_newref(m_newref), .m_side(m_side), .m_shares(m_shares), .m_price(m_price), .m_idx(m_idx),
        .stat_frames_ok(stat_frames_ok), .stat_frames_dropped(stat_frames_dropped), .err_malformed(e_mal)
    );

    order_book #(.NSYM(NSYM), .NLVL(NLVL), .TBITS(TBITS)) u_book (
        .clk(clk), .rst_n(rst_n),
        .m_valid(m_valid), .m_ready(m_ready), .m_type(m_type), .m_locate(m_locate), .m_ref(m_ref),
        .m_newref(m_newref), .m_side(m_side), .m_shares(m_shares), .m_price(m_price), .m_idx(m_idx),
        .bbo_valid(bbo_valid), .bbo_locate(bbo_locate), .bbo_side(bbo_side), .bbo_price(bbo_price),
        .bbo_qty(bbo_qty), .bbo_msg_idx(bbo_msg_idx),
        .err_overflow(e_ovf), .err_collision(e_col), .err_book(e_book)
    );

    assign err_flags = {e_mal, e_ovf, e_col, e_book};
endmodule
