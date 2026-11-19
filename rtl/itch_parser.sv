// Stage 1: Ethernet / IPv4 / UDP / MoldUDP64 filter and ITCH 5.0 message framer.
//
// Input is a 64-bit AXI-Stream (10GbE MAC user side at 156.25 MHz), byte 0 of
// the frame in tdata[7:0], tkeep contiguous from bit 0, FCS already stripped.
//
// Bytes are appended to a 128-byte realignment buffer; complete items
// (the 62-byte header, then each 2-byte-length-prefixed message) are popped
// from the front, so every message is presented byte-aligned to the decoder
// regardless of where it fell inside the 64-bit beats. One message can be
// popped per clock while up to 8 bytes arrive, which keeps up with line rate
// for any message of 8 bytes or more (all ITCH messages are >= 11 bytes).
//
// Frames that are not IPv4/UDP to cfg_udp_port are discarded.
module itch_parser (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] cfg_udp_port,

    input  wire [63:0] s_tdata,
    input  wire [7:0]  s_tkeep,
    input  wire        s_tvalid,
    input  wire        s_tlast,
    output wire        s_tready,

    // decoded message (held while !m_ready)
    output reg         m_valid,
    input  wire        m_ready,
    output reg  [7:0]  m_type,
    output reg  [15:0] m_locate,
    output reg  [63:0] m_ref,
    output reg  [63:0] m_newref,
    output reg         m_side,        // 0 buy, 1 sell
    output reg  [31:0] m_shares,
    output reg  [31:0] m_price,
    output reg  [31:0] m_idx,         // running message number (all messages of accepted frames)

    output reg  [31:0] stat_frames_ok,
    output reg  [31:0] stat_frames_dropped,
    output reg         err_malformed   // sticky: frame ended inside a message
);
    localparam integer BUFB = 128;
    localparam integer HDR  = 62;            // 14 Ethernet + 20 IPv4 + 8 UDP + 20 MoldUDP64
    localparam [1:0] S_HDR = 2'd0, S_MSG = 2'd1, S_DROP = 2'd2;

    reg [8*BUFB-1:0] buff;
    reg [7:0]        cnt;                    // valid bytes in buff
    reg [1:0]        st;
    reg              last_seen;              // tlast of the current frame is already in buff

    // byte view of the buffer (a wire array, so every reader is properly sensitive to buff)
    wire [7:0] bb [0:BUFB-1];
    genvar gi;
    generate
        for (gi = 0; gi < BUFB; gi = gi + 1) begin : g_bytes
            assign bb[gi] = buff[8*gi +: 8];
        end
    endgenerate

    // ------------------------------------------------------------ header check
    wire hdr_ok = ({bb[12], bb[13]} == 16'h0800) && (bb[14] == 8'h45) && (bb[23] == 8'd17)
                  && ({bb[36], bb[37]} == cfg_udp_port);

    // ------------------------------------------------------------ message framing
    wire [15:0] mlen    = {bb[0], bb[1]};
    wire [8:0]  need    = mlen[8:0] + 9'd2;
    wire        have_msg = (st == S_MSG) && (cnt >= 8'd2) && (mlen <= 16'd100) && ({1'b0, cnt} >= need);
    wire        pop_msg  = have_msg && (!m_valid || m_ready);

    // field extraction (message starts at buffer byte 2)
    wire [63:0] f_ref    = {bb[13], bb[14], bb[15], bb[16], bb[17], bb[18], bb[19], bb[20]};
    wire [63:0] f_newref = {bb[21], bb[22], bb[23], bb[24], bb[25], bb[26], bb[27], bb[28]};
    wire [31:0] f_be21   = {bb[21], bb[22], bb[23], bb[24]};
    wire [31:0] f_be22   = {bb[22], bb[23], bb[24], bb[25]};
    wire [31:0] f_be29   = {bb[29], bb[30], bb[31], bb[32]};
    wire [31:0] f_be33   = {bb[33], bb[34], bb[35], bb[36]};
    wire [31:0] f_be34   = {bb[34], bb[35], bb[36], bb[37]};

    wire [7:0] ty = bb[2];

    // ------------------------------------------------------------ pop amount / frame end
    reg [7:0] pop;
    reg [1:0] st_n;
    reg       frame_done;
    always @* begin
        pop = 8'd0; st_n = st; frame_done = 1'b0;
        case (st)
            S_HDR: if (cnt >= HDR) begin
                pop  = HDR;
                st_n = hdr_ok ? S_MSG : S_DROP;
            end else if (last_seen) begin            // runt frame
                pop = cnt; st_n = S_DROP;
            end
            S_MSG: begin
                if (pop_msg) pop = need[7:0];
                if (cnt >= 8'd2 && mlen > 16'd100) begin  // corrupt length: discard the rest of the frame
                    pop = cnt; st_n = S_DROP;
                end else if (last_seen && (cnt - pop) == 8'd0) begin
                    frame_done = 1'b1; st_n = S_HDR;
                end else if (last_seen && !have_msg && cnt != 8'd0) begin
                    pop = cnt; frame_done = 1'b1; st_n = S_HDR;   // truncated message: flush
                end
            end
            default: begin                           // S_DROP: swallow the rest of the frame
                pop = cnt;
                if (last_seen) begin frame_done = 1'b1; st_n = S_HDR; end
            end
        endcase
    end

    // ------------------------------------------------------------ input acceptance
    assign s_tready = !last_seen && (cnt <= BUFB - 8);
    wire       accept = s_tvalid && s_tready;
    wire [3:0] nb = s_tkeep[7] ? 4'd8 : s_tkeep[6] ? 4'd7 : s_tkeep[5] ? 4'd6 : s_tkeep[4] ? 4'd5 :
                    s_tkeep[3] ? 4'd4 : s_tkeep[2] ? 4'd3 : s_tkeep[1] ? 4'd2 : s_tkeep[0] ? 4'd1 : 4'd0;
    wire [7:0] keep_cnt = cnt - pop;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buff <= {8*BUFB{1'b0}}; cnt <= 8'd0; st <= S_HDR; last_seen <= 1'b0;
            m_valid <= 1'b0; m_type <= 8'd0; m_locate <= 16'd0; m_ref <= 64'd0; m_newref <= 64'd0;
            m_side <= 1'b0; m_shares <= 32'd0; m_price <= 32'd0; m_idx <= 32'hFFFFFFFF;
            stat_frames_ok <= 32'd0; stat_frames_dropped <= 32'd0; err_malformed <= 1'b0;
        end else begin
            // buffer: drop `pop` bytes from the front, append the new beat behind what is left
            buff <= (buff >> {pop, 3'b000})
                  | (accept ? ({{(8*BUFB-64){1'b0}}, s_tdata & {{8{s_tkeep[7]}}, {8{s_tkeep[6]}}, {8{s_tkeep[5]}},
                                {8{s_tkeep[4]}}, {8{s_tkeep[3]}}, {8{s_tkeep[2]}}, {8{s_tkeep[1]}}, {8{s_tkeep[0]}}}}
                               << {keep_cnt, 3'b000}) : {8*BUFB{1'b0}});
            cnt <= keep_cnt + (accept ? {4'd0, nb} : 8'd0);
            st  <= st_n;
            if (accept && s_tlast) last_seen <= 1'b1;
            if (frame_done)        last_seen <= 1'b0;

            if (st == S_HDR && cnt >= HDR) begin
                if (hdr_ok) stat_frames_ok      <= stat_frames_ok + 32'd1;
                else        stat_frames_dropped <= stat_frames_dropped + 32'd1;
            end else if (st == S_HDR && last_seen) begin
                stat_frames_dropped <= stat_frames_dropped + 32'd1;
            end
            if (st == S_MSG && ((last_seen && !have_msg && cnt != 8'd0) || (cnt >= 8'd2 && mlen > 16'd100)))
                err_malformed <= 1'b1;

            if (m_valid && m_ready) m_valid <= 1'b0;
            if (pop_msg) begin
                m_valid  <= 1'b1;
                m_idx    <= m_idx + 32'd1;
                m_type   <= ty;
                m_locate <= {bb[3], bb[4]};
                m_ref    <= f_ref;
                m_newref <= f_newref;                       // 'U' new reference
                m_side   <= (bb[21] == "S");                 // 'A' side byte
                case (ty)
                    "A":      begin m_shares <= f_be22; m_price <= f_be34; end
                    "E", "X": begin m_shares <= f_be21; m_price <= 32'd0;     end
                    "U":      begin m_shares <= f_be29; m_price <= f_be33; end
                    default:  begin m_shares <= 32'd0;     m_price <= 32'd0;     end
                endcase
            end
        end
    end
endmodule
