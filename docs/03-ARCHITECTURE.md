# 03 — Kiến trúc & cấu trúc thư mục

## 1. Luồng dữ liệu — Video

```
 [videotestsrc]        nguồn video giả lập, thay cho camera CSI
       │  raw video (I420, 1280x720, 30fps)
       ▼
 [timeoverlay]         in timestamp lên hình → để đo latency bằng mắt
       │
 [videoconvert]        đổi color format cho khớp encoder
       │
 [x264enc]             nén H.264. tune=zerolatency → lookahead=0 + sliced threads
       │  H.264 elementary stream
       ▼
 [rtph264pay]          cắt thành RTP packet, thêm seq number + timestamp
       │  RTP packets
       ▼
 [udpsink] ──────► UDP 127.0.0.1:5000 ──────► [udpsrc]
                   (tc netem chèn loss/jitter ở đây)   │
                                                        ▼
                                              [rtpjitterbuffer]   sắp xếp lại gói, bù jitter
                                                        │          ← latency=0 để giảm trễ
                                                        ▼
                                              [rtph264depay]      ghép RTP lại thành H.264
                                                        │
                                                        ▼
                                              [avdec_h264]        giải nén
                                                        │  raw video
                                                        ▼
                                              [appsink]           C++ app lấy frame ra ở đây
                                                        │
                                                        ▼
                                              receiver.cpp: đếm frame, đọc PTS, in stats
```

**Ranh giới mạng** nằm đúng giữa `udpsink` và `udpsrc`. Mọi thứ bên trái chạy trên companion computer (Jetson) ngoài đời thật; mọi thứ bên phải chạy trên ground station. Trong project, cả hai chạy trên cùng một máy qua loopback.

## 2. Luồng dữ liệu — MAVLink

```
 [ArduPilot SITL]  ── UDP 14550 ──►  [gateway.py]
   (giả lập FC)      MAVLink v2         │
        ▲                               ├──► watchdog: mất heartbeat 3s → LINK LOST
        │                               ├──► telemetry.csv / telemetry.jsonl
        └───── COMMAND_LONG ────────────┤
              (arm/takeoff/land)        └──► MQTT: topic drone/telemetry  [P2]
        ┌───── COMMAND_ACK ─────────────┘
        ▼
     gateway đọc ACK, không "bắn rồi quên"
```

Điểm cần nhớ: MAVLink là **giao thức hai chiều bất đối xứng**. Telemetry được FC **phát liên tục** không cần ai hỏi (streaming). Còn lệnh thì theo mô hình **request/ack** — gửi `COMMAND_LONG`, chờ `COMMAND_ACK`.

## 3. Cây thư mục

```
drone-video-link/
├── README.md                  ← mặt tiền, tiếng Anh, cho nhà tuyển dụng đọc
├── .gitignore
│
├── docs/                      ← sổ tay kỹ thuật, tiếng Việt, cho bạn đọc
│   ├── 00-OVERVIEW.md         bài toán thật vs mô phỏng, ranh giới scope
│   ├── 01-PLAN.md             kế hoạch 2 ngày, DoD, fallback
│   ├── 02-STATE.md            tiến độ — CẬP NHẬT LIÊN TỤC
│   ├── 03-ARCHITECTURE.md     file này
│   ├── 04-CONCEPTS.md         giải thích mọi khái niệm
│   ├── 05-DECISIONS.md        vì sao chọn thế này
│   ├── 06-INTERVIEW-QA.md     câu hỏi phỏng vấn
│   └── assets/                ảnh, sơ đồ, screenshot
│
├── video/                     ← Ngày 1
│   ├── README.md              cách chạy + kết quả đo (tiếng Anh)
│   ├── CMakeLists.txt         build receiver.cpp
│   ├── include/               header nếu tách file
│   ├── src/
│   │   └── receiver.cpp       ★ app C++ dùng GStreamer C API + appsink
│   ├── scripts/
│   │   ├── common.sh          hằng số mạng + chuỗi encoder; mọi script đều source
│   │   ├── sender.sh          pipeline gửi (gst-launch)
│   │   ├── receiver.sh        pipeline nhận tham chiếu (gst-launch)
│   │   ├── measure-latency.sh chạy với GST_TRACERS
│   │   ├── netem.sh           bật/tắt giả lập mạng xấu           [root]
│   │   ├── demo.sh            kịch bản netem cho demo trực tiếp   [root]
│   │   ├── record-demo.sh     quay demo.mp4 headless              [root]
│   │   ├── packet-loss.sh     hai bảng giao nhận, hai dụng cụ đo  [root]
│   │   ├── pattern-damage.sh  ảnh thử có che mất hỏng hóc không?  [root]
│   │   ├── make-stream.sh     đóng băng bitstream (x264enc không tái lập được)
│   │   ├── gop-stats.sh       đọc NAL Annex-B: cấu trúc GOP, mô hình gói
│   │   ├── capture-frames.sh  ghi từng ảnh đã giải mã ra PNG + RGB thô
│   │   ├── frame-diff.sh      sai khác từng pixel, gom thành "đợt hỏng"
│   │   └── idr-vs-p.sh        xoá đúng một slice NAL rồi giải mã
│   └── results/
│       ├── latency.md         BẢNG SỐ LIỆU — thứ đi lên CV
│       ├── packet-loss.md     screenshot + giải thích
│       ├── img/*.png          ảnh sạch / vỡ / hồi phục
│       └── loss-*.log         log gốc của receiver (trace-*.log bị gitignore)
│
└── mavlink/                   ← Ngày 2
    ├── README.md
    ├── requirements.txt       pymavlink, MAVProxy, paho-mqtt
    ├── gateway/
    │   ├── __init__.py        docstring: MAVLink hai chiều bất đối xứng
    │   ├── connection.py      kết nối UDP, wait_heartbeat, học system id
    │   ├── watchdog.py        máy trạng thái edge-triggered, clock tiêm được
    │   ├── telemetry.py       parse + scale SI, gộp 1 snapshot, logger CSV/JSONL
    │   ├── commands.py        arm/takeoff/land, khớp COMMAND_ACK, đúng thứ tự
    │   ├── mqtt_bridge.py     publish snapshot lên broker            [P2]
    │   └── cli.py             entrypoint: monitor / takeoff / land / arm
    ├── scripts/
    │   ├── run-sitl.sh        khởi động ArduPilot SITL           [cần tree đã build]
    │   └── mock_fc.py         FC giả cho lặp nhanh; trả lời lệnh, stream GPS
    ├── tests/
    │   └── test_watchdog.py   7 test cho logic failsafe, clock giả
    └── logs/                  telemetry.csv/.jsonl (gitignored);
                               telemetry.sample.* (từ SITL thật, giữ làm bằng chứng)
```

**Đã kiểm chứng với ArduPilot SITL thật.** Gateway chạy end-to-end với một bản
build ArduCopter SITL (x86, EKF thật, pre-arm thật, qua TCP 5760): `takeoff 10`
arm và leo tới 10 m, lặp lại được qua nhiều lần khởi động lạnh. `mock_fc.py` là để
lặp nhanh, nhưng nó và gateway chung một cách hiểu spec nên **không** phải kiểm
chứng độc lập — và đúng như thế, SITL bắt được **hai lỗi mock giấu**: (1) ArduPilot
không stream telemetry nếu GCS không gửi `REQUEST_DATA_STREAM`; (2) bit sức khoẻ
sensor xanh *trước* khi thật sự arm được (cần GPS 3D fix + EKF origin), nên arm một
lần là thua cuộc đua. Cả hai đã sửa. Chi tiết ở `mavlink/README.md`.

## 4. Vì sao một repo, không phải hai

Hai project rời (`video-streaming` và `mavlink-gateway`) đọc như hai bài tutorial. Một repo tên `drone-video-link` với sơ đồ ở README đọc như **một hệ thống**: "tôi làm phần ground-station link cho drone."

Nhà tuyển dụng lướt CV khoảng 15 giây. Một repo có câu chuyện thắng hai repo có tính năng.

Bạn **vẫn viết được hai bullet CV** từ một repo — không mất gì.

Lưu ý: hai thành phần **không cần tích hợp code với nhau**. Chúng chỉ chia sẻ một README và một sơ đồ. Việc ép chúng nói chuyện với nhau sẽ tốn cả ngày mà không thêm giá trị.

## 5. Quy ước

- Script shell đặt trong `scripts/`, luôn có `set -euo pipefail` ở đầu.
- Mọi hằng số mạng (`5000`, `14550`, `127.0.0.1`) khai báo ở đầu file, không rải rác.
- File trong `results/` là **sản phẩm cuối**, viết cho người ngoài đọc, không phải nháp.
- Commit message: `video:` / `mavlink:` / `docs:` làm prefix.
