# 01 — Kế hoạch 2 ngày

## Nguyên tắc chia việc

Mỗi task có **Definition of Done (DoD)** cụ thể — không phải "làm xong phần video" mà là "chạy được lệnh X, thấy kết quả Y". Nếu hết giờ mà chưa đạt DoD, **chuyển sang fallback**, đừng cố.

Ưu tiên theo cột **P**: `P0` = không có thì project vô nghĩa. `P1` = thứ tạo ra khác biệt trên CV. `P2` = có thì tốt.

---

## NGÀY 1 — Video downlink

Mục tiêu cuối ngày: **một con số latency tính bằng ms, và một file `receiver.cpp` tự viết.**

### T1.1 — Dựng môi trường (60 phút) · P0

Cài GStreamer trong WSL Ubuntu 22.04, xác nhận từng plugin tồn tại.

**DoD:**
```bash
gst-launch-1.0 videotestsrc num-buffers=100 ! autovideosink   # thấy cửa sổ có hình
gst-inspect-1.0 x264enc | head -3                              # plugin tồn tại
gst-inspect-1.0 rtph264pay | head -3
gst-inspect-1.0 avdec_h264 | head -3
```

**Bẫy:** `x264enc` nằm trong `plugins-ugly`, `avdec_h264` nằm trong `gstreamer1.0-libav`, `fpsdisplaysink` nằm trong `plugins-bad`. Thiếu package nào thì `gst-inspect` báo không tìm thấy element, chứ pipeline không tự nói cho bạn.

**Bẫy WSL:** cửa sổ hiển thị chạy qua WSLg. Nếu `autovideosink` lỗi, thử `ximagesink` hoặc `xvimagesink`.

---

### T1.2 — Sender/receiver bằng `gst-launch` (120 phút) · P0

Chạy được video qua RTP/UDP giữa hai terminal, **chưa cần viết code**. Đây là bước để hiểu pipeline trước khi lập trình nó.

**DoD:** terminal A gửi, terminal B hiện hình chuyển động, không giật.

Pipeline tham chiếu — **đừng copy mù, tra từng element trong [04-CONCEPTS.md](04-CONCEPTS.md)**:

```bash
# Sender
gst-launch-1.0 -v \
  videotestsrc is-live=true pattern=smpte ! \
  video/x-raw,width=1280,height=720,framerate=30/1 ! \
  timeoverlay ! videoconvert ! \
  x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 ! \
  rtph264pay config-interval=1 pt=96 ! \
  udpsink host=127.0.0.1 port=5000

# Receiver
gst-launch-1.0 -v \
  udpsrc port=5000 caps="application/x-rtp,media=video,encoding-name=H264,payload=96" ! \
  rtpjitterbuffer latency=0 ! rtph264depay ! avdec_h264 ! \
  videoconvert ! fpsdisplaysink sync=false
```

**Checkpoint hiểu bài** — trả lời được 3 câu này rồi mới đi tiếp:
1. Nếu bỏ `config-interval=1` thì chuyện gì xảy ra khi receiver khởi động sau sender?
2. `sync=false` ở sink làm gì? Bỏ nó đi thì latency thay đổi thế nào?
3. Vì sao `caps` phải khai báo thủ công ở `udpsrc` mà không tự negotiate được?

---

### T1.3 — Receiver bằng C++ + CMake (180 phút) · P1 ★ quan trọng nhất

Viết lại receiver thành ứng dụng C++ dùng GStreamer C API, lấy frame ra qua `appsink`, in thống kê.

Đây là phần **quyết định giá trị CV của cả project**. Không có nó, bạn chỉ là người gõ lệnh terminal.

**DoD:**
```bash
cd video && cmake -B build && cmake --build build
./build/receiver --port 5000
# in ra: frame count, resolution, timestamp mỗi frame
```

**Phạm vi tối thiểu (đừng làm hơn):**
- `gst_parse_launch()` để dựng pipeline (không cần `gst_element_factory_make` từng element)
- `appsink` với callback `new-sample`
- Lấy `GstBuffer`, đọc `GST_BUFFER_PTS`, đếm frame
- `GMainLoop`, xử lý bus message (`ERROR`, `EOS`)
- `CMakeLists.txt` dùng `pkg-config` tìm `gstreamer-1.0`, `gstreamer-app-1.0`

**Fallback nếu quá 3 tiếng:** giữ pipeline bằng `gst_parse_launch`, bỏ `appsink`, chỉ cần app C++ chạy được pipeline + bắt bus error. Vẫn có CMake, vẫn có C++, vẫn tốt hơn shell script.

---

### T1.4 — Đo latency (60 phút) · P1

**DoD:** một bảng trong `video/results/latency.md` có ít nhất 3 dòng.

```bash
GST_DEBUG="GST_TRACER:7" GST_TRACERS="latency(flags=pipeline+element)" \
  gst-launch-1.0 <pipeline> 2>&1 | tee results/trace-tuned.log
```

Bảng cần đo:

| Cấu hình | Latency |
|---|---|
| Default (`x264enc` mặc định, `rtpjitterbuffer latency=200`, `sync=true`) | ? |
| `tune=zerolatency` | ? |
| `+ rtpjitterbuffer latency=0` | ? |
| `+ sink sync=false` | ? |

Mỗi dòng phải kèm **một câu giải thích vì sao con số giảm**. Bảng không có giải thích thì vô dụng.

---

### T1.5 — Thí nghiệm mất gói với `tc netem` (60 phút) · P1

**DoD:** 2 screenshot (bình thường / vỡ hình) + đoạn giải thích trong `results/packet-loss.md`.

```bash
sudo tc qdisc add dev lo root netem loss 2% delay 20ms 5ms   # bật
sudo tc qdisc show dev lo                                     # kiểm tra
sudo tc qdisc del dev lo root                                 # tắt
```

**Câu hỏi phải trả lời:** vì sao mất *một* gói lại làm hỏng hình trong *cả giây*, chứ không phải một frame? (Gợi ý: GOP, `key-int-max=30`, P-frame tham chiếu frame trước.)

---

### T1.6 — README + demo video (60 phút) · P0

**DoD:** README của `video/` có: pipeline, cách chạy, bảng latency, screenshot packet loss, và **mục "Mapping to Jetson Orin NX"**.

Mục mapping viết đúng 3–4 dòng, đại ý: trên Jetson, `x264enc` được thay bằng `nvv4l2h264enc` (hardware encoder, NVENC), `videoconvert` thay bằng `nvvidconv`; phần RTP/UDP và receiver giữ nguyên. Câu này tốn 2 phút viết và cho thấy bạn hiểu nền tảng đích.

Quay demo 30–60 giây: hai terminal cạnh nhau, bật netem giữa chừng cho vỡ hình, tắt đi cho hồi phục.

---

## NGÀY 2 — MAVLink gateway

Mục tiêu cuối ngày: **gateway Python nói chuyện được với SITL, có watchdog, có log.**

### T2.1 — Dựng ArduPilot SITL (90 phút, TIMEBOX CỨNG) · P0

**DoD:**
```bash
sim_vehicle.py -v ArduCopter --out=udp:127.0.0.1:14550
# thấy log "APM: ArduCopter Vxxx" và heartbeat chạy
```

> ⚠️ **Đây là task rủi ro nhất của cả project.** Build ArduPilot từ source mất 30–60 phút nếu suôn sẻ, và dễ hỏng vì thiếu dependency Python. Hết 90 phút mà chưa chạy được thì **dừng ngay**, sang fallback.

**Fallback:** dùng Docker image có sẵn SITL, hoặc viết một `mock_fc.py` dùng `pymavlink` tự phát `HEARTBEAT` + `ATTITUDE` giả ra UDP 14550. Gateway vẫn phát triển bình thường; ghi rõ trong README là dùng mock. Quay lại SITL sau khi gateway xong.

---

### T2.2 — Gateway: kết nối + heartbeat + watchdog (120 phút) · P0

**DoD:** gateway in heartbeat mỗi giây; rút SITL ra thì trong 3 giây báo `LINK LOST`.

```python
from pymavlink import mavutil
m = mavutil.mavlink_connection('udpin:0.0.0.0:14550')
m.wait_heartbeat()
```

Watchdog: theo spec MAVLink, heartbeat phát ở 1Hz; mất 3 nhịp liên tiếp thì coi như đứt link. Đây là logic **an toàn bay** thật, không phải chi tiết trang trí — nói được điều này trong phỏng vấn là ghi điểm.

---

### T2.3 — Telemetry parsing + logging (90 phút) · P0

**DoD:** file `logs/telemetry.csv` và `logs/telemetry.jsonl` có dữ liệu thật từ SITL.

Message cần bắt: `HEARTBEAT` (flight mode, armed), `GLOBAL_POSITION_INT` (lat/lon/alt), `ATTITUDE` (roll/pitch/yaw), `VFR_HUD` (groundspeed), `SYS_STATUS` hoặc `BATTERY_STATUS` (pin).

**Bẫy:** MAVLink gửi số nguyên đã scale. `GLOBAL_POSITION_INT.lat` là `degE7` — chia `1e7`. `alt` là mm. `ATTITUDE.roll` là radian. Sai chỗ này là log ra rác.

---

### T2.4 — Command: arm / takeoff / land (90 phút) · P1

**DoD:** chạy `python gateway/cli.py takeoff 10` → nhìn SITL leo lên 10m, log `alt` tăng dần.

Trình tự **bắt buộc đúng thứ tự**, đây là chỗ 90% người mới sai:
1. Set mode `GUIDED`
2. Chờ EKF sẵn sàng / GPS lock (SITL mất ~20–30s)
3. Arm: `MAV_CMD_COMPONENT_ARM_DISARM` (id 400), `param1=1`
4. Takeoff: `MAV_CMD_NAV_TAKEOFF` (id 22), `param7 = altitude`

Nếu arm trước khi set GUIDED, hoặc takeoff khi chưa arm, FC **từ chối lệnh** và trả `COMMAND_ACK` với result khác `ACCEPTED`. Gateway phải đọc `COMMAND_ACK` chứ không được bắn lệnh rồi cho là xong.

---

### T2.5 — MQTT bridge (60 phút) · P2

**DoD:** telemetry đẩy lên topic `drone/telemetry`, `mosquitto_sub` thấy dữ liệu.

Rẻ, khoảng 40 dòng với `paho-mqtt`, và phủ đúng một gạch đầu dòng trong JD ("tích hợp hệ thống nhúng với Cloud: MQTT"). Bỏ được nếu thiếu giờ.

---

### T2.6 — Sơ đồ kiến trúc + README (60 phút) · P0

**DoD:** README gốc có sơ đồ, cả hai sub-README hoàn chỉnh, [02-STATE.md](02-STATE.md) cập nhật.

---

## Việc vét, nếu còn giờ (P2)

| Việc | Giờ | Phủ gạch đầu dòng nào trong JD |
|---|---|---|
| `Dockerfile` cho project video | 1h | "Containerization (Docker) cho build và deploy" |
| Demo FFmpeg `vidstabdetect` + `vidstabtransform` | 1h | "Tham gia dự án chống rung hình ảnh trên drone" |
| GitHub Actions build `receiver.cpp` | 30m | "Nắm cơ bản về DevOps cho hệ thống nhúng" |

Demo vidstab: quay/tải một clip rung, chạy 2 pass, ghép before/after cạnh nhau. Không tự viết thuật toán — mục đích chỉ là chứng minh bạn đọc JD và biết bài toán đó tồn tại.

---

## Cái KHÔNG làm, và vì sao

- **Yocto / Buildroot** — build đầu tiên 4–8 tiếng, ngốn 50GB disk, và demo ra được là một dòng chữ `login:`. Tỉ lệ giá trị trên thời gian tệ nhất trong mọi lựa chọn.
- **Wokwi FreeRTOS ESP32** — CV đã có STM32/CAN/IMU thật. Thêm một project mô phỏng mức nhập môn sẽ *làm loãng*, không làm mạnh.
- **Camera thật, drone thật** — không thêm kiến thức nào mà pipeline giả lập chưa dạy.
- **Tự viết thuật toán chống rung** — vài ngày công, nằm ngoài scope.
