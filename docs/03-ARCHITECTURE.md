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
 [x264enc]             nén H.264. tune=zerolatency → không B-frame
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
│   │   ├── sender.sh          pipeline gửi (gst-launch)
│   │   ├── receiver.sh        pipeline nhận tham chiếu (gst-launch)
│   │   ├── measure-latency.sh chạy với GST_TRACERS
│   │   └── netem.sh           bật/tắt giả lập mạng xấu
│   └── results/
│       ├── latency.md         BẢNG SỐ LIỆU — thứ đi lên CV
│       ├── packet-loss.md     screenshot + giải thích
│       └── *.log              raw trace
│
└── mavlink/                   ← Ngày 2
    ├── README.md
    ├── requirements.txt       pymavlink, paho-mqtt
    ├── gateway/
    │   ├── connection.py      kết nối UDP, wait_heartbeat
    │   ├── watchdog.py        phát hiện mất link
    │   ├── telemetry.py       parse message, scale đơn vị
    │   ├── commands.py        arm / takeoff / land, đọc COMMAND_ACK
    │   ├── mqtt_bridge.py     [P2]
    │   └── cli.py             entrypoint
    ├── scripts/
    │   ├── run-sitl.sh        khởi động ArduPilot SITL
    │   └── mock_fc.py         FALLBACK: giả lập FC nếu SITL không dựng được
    └── logs/                  telemetry.csv, telemetry.jsonl (gitignored)
```

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
