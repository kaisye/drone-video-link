# 02 — Trạng thái hiện tại

> **Cách dùng file này:** cập nhật sau *mỗi* task xong, không để dồn cuối ngày. Khi quay lại làm việc sau khi nghỉ, đọc file này trước tiên. Nếu bạn (hoặc AI assistant) mở lại project sau vài ngày, đây là file duy nhất cần đọc để biết đang đứng ở đâu.

**Cập nhật lần cuối:** 2026-07-10, hết Ngày 2 (gateway MAVLink xong, đã kiểm chứng với **ArduPilot SITL thật**)
**Đang làm:** — (xong 12/12 task chính; còn việc vét P2)
**Blocker hiện tại:** — không còn. SITL build xong (mạng hồi phục), `takeoff 10` chạy thật: arm + leo tới 10 m, lặp lại được.

**Môi trường:** WSL2 `Ubuntu-22.04` (chú ý: distro mặc định là `docker-desktop`, phải gọi `wsl -d Ubuntu-22.04`). GStreamer 1.20.3, g++ 11.4, cmake 3.22, 16 lõi. `tc netem` cần chạy bằng root (`wsl -d Ubuntu-22.04 -u root`).

---

## Bảng tiến độ

Ký hiệu: `[ ]` chưa làm · `[~]` đang làm · `[x]` xong, đạt DoD · `[!]` bị chặn · `[-]` bỏ, có lý do

### Ngày 1 — Video

| | Task | P | DoD đạt chưa | Ghi chú |
|---|---|---|---|---|
| `[x]` | T1.1 Dựng môi trường GStreamer | P0 | ✔ 13/13 element | netem chỉ chạy được với root |
| `[x]` | T1.2 Sender/receiver `gst-launch` | P0 | ✔ 235 frame, 0 drop, 30.01 fps | |
| `[x]` | T1.3 **Receiver C++ + CMake** | P1 ★ | ✔ build sạch, valgrind sạch | |
| `[x]` | T1.4 Đo latency | P1 | ✔ 2288 ms → 7.8 ms | phát hiện giả định B-frame sai |
| `[x]` | T1.5 Thí nghiệm `tc netem` | P1 | ✔ 3 ảnh + `packet-loss.md` | `discont` không bắt được mất gói |
| `[x]` | T1.6 README + demo video | P0 | ✔ README + `demo.mp4` 31 s | `pinwheel` hoá ra **đứng yên** |

### Ngày 2 — MAVLink

| | Task | P | DoD đạt chưa | Ghi chú |
|---|---|---|---|---|
| `[x]` | T2.1 ArduPilot SITL (timebox 90') | P0 | ✔ build xong, `takeoff 10` leo tới 10 m | mạng chậm suýt phải bỏ; hồi phục kịp; mock vẫn giữ làm dev tool |
| `[x]` | T2.2 Heartbeat + watchdog | P0 | ✔ LINK LOST 3,0–3,5s, unit test 7/7 | clock tiêm được nên test không phải `sleep` |
| `[x]` | T2.3 Telemetry parsing + logging | P0 | ✔ CSV+JSONL, scale đúng | 161 dòng/lần chạy, lat/alt/att/pin đúng đơn vị |
| `[x]` | T2.4 Arm / takeoff / land | P1 | ✔ đọc COMMAND_ACK, đúng thứ tự | arm trước GUIDED → TEMPORARILY_REJECTED |
| `[x]` | T2.5 MQTT bridge | P2 | ✔ publish `drone/telemetry`, retained | paho-mqtt optional, thiếu thì cảnh báo |
| `[x]` | T2.6 Sơ đồ + README | P0 | ✔ mavlink/README + cập nhật docs | |

### Vét

| | Task | P | |
|---|---|---|---|
| `[ ]` | Dockerfile cho `video/` | P2 | |
| `[ ]` | Demo FFmpeg vidstab | P2 | |
| `[ ]` | GitHub Actions | P2 | |

---

## Checkpoint hiểu bài

Project chỉ coi là thành công khi bạn tự trả lời được, **không mở tài liệu**:

- `[ ]` Vì sao video dùng UDP mà không dùng TCP?
- `[ ]` RTP thêm gì lên trên UDP, và vì sao cần?
- `[ ]` `rtpjitterbuffer latency` đánh đổi cái gì lấy cái gì?
- `[ ]` `tune=zerolatency` thực chất tắt những gì trong x264?
- `[ ]` `sync=false` ở sink nghĩa là gì?
- `[ ]` Mất 1 gói UDP, vì sao hình vỡ cả giây chứ không phải 1 frame?
- `[ ]` Vì sao "hỏng nửa GOP" là câu trả lời sai, và câu đúng phụ thuộc vào cái gì?
- `[ ]` Ứng dụng làm sao biết đang mất gói? Vì sao `discont`/`CORRUPTED` vô dụng?
- `[ ]` `latency=0` phải trả giá bao nhiêu khi mạng có jitter?
- `[ ]` `appsink` khác `autovideosink` chỗ nào, và khi nào cần?
- `[ ]` Caps negotiation là gì, vì sao `udpsrc` phải khai caps thủ công?
- `[ ]` MAVLink heartbeat mất bao lâu thì coi là đứt link, vì sao con số đó?
- `[ ]` Vì sao phải set mode GUIDED trước khi arm?
- `[ ]` Trên Jetson, pipeline này đổi những element nào?

Đánh dấu `[x]` khi tự giải thích được thành lời cho người khác nghe. Chi tiết ở [04-CONCEPTS.md](04-CONCEPTS.md).

---

## Nhật ký

Ghi ngắn: làm gì, hỏng ở đâu, sửa thế nào. Phần "hỏng ở đâu" là phần đáng giá nhất khi phỏng vấn — người ta hỏi *"kể một lỗi khó em từng debug"* thì đây là chỗ lấy câu trả lời.

```
YYYY-MM-DD HH:MM — <task> — <việc đã làm> — <vấn đề gặp> — <cách xử lý>
```

**2026-07-10 — T1.1** — Cài GStreamer trong WSL. `sudo` đòi mật khẩu, nhưng `wsl -u root` vào thẳng được root không cần password. `tc netem` chỉ hoạt động dưới root — ghi nhớ cho T1.5.

**2026-07-10 — T1.2** — Chạy sender/receiver headless. Không có gì hỏng. 235 frame, 0 drop.

**2026-07-10 — T1.3** — Viết `receiver.cpp`. Hai lỗi:
1. **`discont=1` ngay frame đầu.** Buffer đầu tiên của mọi stream luôn mang cờ `GST_BUFFER_FLAG_DISCONT` — một stream bắt đầu thì đương nhiên không liên tục. Nếu đếm nó thì baseline lúc mạng hoàn hảo là 1 chứ không phải 0, và cả thí nghiệm T1.5 đọc sai. Đã bỏ qua frame đầu.
2. **Valgrind báo `definitely lost: 16,448 bytes`.** Nhìn stack trace thì nó nằm trong glib/rtpmanager, có vẻ vô can — nhưng suy luận từ stack không phải bằng chứng. Chạy lại hai lần: 50 frame → 16448 bytes, 173 frame → 16448 bytes. Không đổi ⇒ rò một lần, không phải rò theo frame. Phần lớn được cấp phát trong `_dl_init`, tức trước cả `main()`.

**2026-07-10 — T1.4** — Đo latency. **Đây là task dạy được nhiều nhất.**
- Tôi đã tin (và đã viết vào docs, vào comment code, vào cả CV) rằng `tune=zerolatency` tắt B-frame. **Sai.** `x264enc` của GStreamer mặc định `bframes=0` — không có B-frame nào để tắt. Kiểm bằng `gst-inspect-1.0 x264enc | grep -A2 '^  bframes'`.
- Thủ phạm thật: `rc-lookahead=40` (tốn đúng 40 frame) và frame-based multithreading (tốn ~1 frame mỗi luồng; 28 frame trên máy 16 lõi). Tách bạch bằng cách ép `threads=1` rồi quét từng nút.
- Suýt dựng một cột số liệu trên hư không: `fakesink` **không có** element-latency vì tracer lấy mẫu ở src pad, mà sink thì không có src pad. Con số tôi tưởng là của fakesink thực ra do regex `element=` khớp nhầm vào `sink-element=`.
- `sync=false` chỉ bớt 15 ms, nhưng chỗ nó hiện ra không phải chỗ nó gây hại: khi sink nghẽn, buffer dồn ứ **trong jitter buffer** (15,5 ms → 0,8 ms). Element báo triệu chứng ≠ element có bệnh.
- Mean bị lệch vì lúc EOS encoder xả hàng nhanh, kéo mean xuống dưới giá trị trạng thái ổn định (1623 vs median 2070). Dùng median.

**2026-07-10 — T1.5** — Thí nghiệm `tc netem`. **Dụng cụ đo sai ba lần trước khi đúng.**
1. **`GST_BUFFER_FLAG_DISCONT` không bắt được mất gói.** Tôi đã viết đúng câu đó vào comment của `receiver.cpp` ở T1.3. Quét từ 0→20% loss: ở 20%, mất 474 gói, ứng dụng vẫn nhận 148/150 frame, `discont=0`, `CORRUPTED=0`. `avdec_h264` che lỗi im lặng. Dụng cụ đúng là property `stats` của `rtpjitterbuffer` → `num-lost`, và nó phải được đối chiếu với `tc -s qdisc` của kernel.
2. **`num-lost` cũng nói dối khi có đảo gói.** Link chỉ mất gói: `tc`=101, `num-lost`=101, khớp tuyệt đối. Thêm jitter: `num-lost`=3640 trong khi 4580 gói vẫn được đẩy và 270/300 frame giải mã được. Nó đếm *lần phát hiện khoảng trống*, không phải *gói mất*.
3. **`x264enc` không bit-reproducible.** So hai lần chạy sạch với nhau ra 300/300 frame khác nhau. `md5sum` hai lần encode cùng input tất định → hai file khác nhau. Phải **đóng băng bitstream ra file rồi phát lại** thì control mới cho 600/600 frame trùng khít từng bit.
- Cái bẫy thứ tư: dùng ảnh tĩnh SMPTE thì **không thấy hình vỡ ở đâu cả**. Lúc đó tôi kết luận "ảnh tĩnh giấu hỏng hóc, vì concealment chép khối từ frame trước và với ảnh tĩnh khối đó *đúng*", rồi "chạy lại với ảnh động" bằng `pattern=pinwheel`. **Đến T1.6 mới đo: `pinwheel` đứng yên hoàn toàn (0,0% pixel đổi giữa hai frame).** Xem nhật ký T1.6.
- Kết quả: **10/10 đợt hỏng kết thúc đúng tại một IDR.** Sai lệch không phai (phẳng 22,6 suốt GOP rồi rơi về 0,3 tại IDR, và 0,0 tại IDR sạch).
- Phát hiện phản trực giác: "mất 1 gói hỏng nửa GOP" **sai**. Keyframe chiếm 15% số gói (to gấp 15× P-frame), nên kỳ vọng theo phân bố gói là 17,6 frame, đo được 24,1. Monte Carlo trên đúng layout gói: mô hình 61% GOP hỏng / 20,1 frame, đo được 55% / 24,1 frame.
- Và cái giá của `latency=0` (chọn ở T1.4): jitter ±5 ms, **mất 0 gói** → chỉ giải mã được 67/300 frame. `latency=200` → 270–300/300.

**2026-07-10 — T1.6** — README + demo. Định làm 60 phút, hoá ra phải rút lại một kết luận của T1.5.

- Viết `netem.sh` — file này bị `README.md` và `03-ARCHITECTURE.md` nhắc tới suốt nhưng **chưa bao giờ tồn tại**. Tài liệu mô tả một thứ không có.
- Quay `demo.mp4` bằng `pattern=pinwheel`, xem lại thì **hình hoàn toàn sạch** dù kernel đã vứt 95 gói. Đo thử: `pinwheel` có **0,0%** pixel thay đổi giữa hai frame liên tiếp — nó *đứng yên*. Nghĩa là ở T1.5, cái "chạy lại với ảnh động" đã đổi từ ảnh tĩnh này sang ảnh tĩnh khác, và kết quả vẫn đổi. Vậy "ảnh động" chưa bao giờ là biến số.
- Đo tử tế bằng `pattern-damage.sh` (0,15% loss, 600 picture, 4 pattern): **không pattern nào giấu được hỏng hóc** — cái nào cũng sai 110–155/600 picture. Cái bị giấu là **biên độ**: median sai lệch 0,01/255 (`pinwheel`) → 4,22 (`zone-plate`). Dụng cụ cũ là histogram kích thước file PNG, không thể thấy 0,34/255. Ảnh về sai gần như mọi frame mà **trông vẫn hoàn hảo**.
- **Hai lần dụng cụ lại nói dối, cùng một buổi:**
  1. Cột "worst" là một **cực đại** trên 300 picture → do đúng một slice keyframe có bị trúng hay không quyết định. Chạy hai lần cùng một lệnh: `smpte` cho 2,2 rồi 12,1. Trông như phát hiện, thực ra là tung đồng xu. Đổi sang **median**.
  2. Đợt hỏng cuối cùng bị **cắt cụt bởi cuối bản ghi**, không phải bởi keyframe. Đếm nó vào làm 27/27 tụt xuống 7/8 giữa hai lần chạy, suýt phải rút lại kết quả chính. `frame-diff.sh` giờ loại nó ra và nói rõ.
- Sau khi sửa cả hai: **29/29 đợt hỏng kết thúc đúng tại keyframe**, trên cả 4 pattern. Lần chạy thứ hai 29/31, và cả 2 ngoại lệ đều ở `ball` — nền đen phẳng 98%, khối hỏng render ra *trùng khít từng pixel*, sai lệch đọc đúng 0,000 một vài picture rồi hỏng lại. Lỗi vẫn nằm trong reference buffer của decoder. **Sai lệch pixel đo cái mắt thấy, không đo cái decoder tin.**
- Chạy `idr-vs-p.sh` (xoá đúng một slice NAL khỏi bitstream đã đóng băng rồi giải mã; không random, thử lần lượt cả 11 slice của một IDR và 11 slice của một P). Kết quả **trả lời một câu hỏi và bác bỏ một giả thuyết**:
  1. **Thời gian hỏng không phải thuộc tính của loại frame** — nó chỉ là khoảng cách tới keyframe kế tiếp. IDR ở picture 30 → hỏng `30..59`; P ở picture 15 → hỏng `15..29`. Cả 22 lần thử đều liền mạch, đều kết thúc đúng tại keyframe. Cộng cả hai pattern: **36/36**, không còn phụ thuộc may rủi của netem.
  2. **Biên độ mới là thuộc tính của loại frame: mất slice IDR tệ hơn 5,8×** (10,69 so với 1,85). Và nó **được định đoạt ngay tại frame bị trúng**, chứ không phải do lỗi tích luỹ lâu hơn: median đỉnh chỉ hơn median tại-điểm-trúng 3%. Che một dải *intra* mới là việc khó.
  3. **Nghi phạm được minh oan.** Tôi đã viết vào tài liệu rằng `pinwheel` vỡ ở 2% loss là vì mất slice của IDR. Sai: mất một slice IDR trên `pinwheel` chỉ cho đỉnh **0,23/255**, trong khi ảnh vỡ ở 2% phẳng lì ở **22,6/255** — gấp 100 lần. Tệ hơn 5,8 lần so với *không có gì* thì vẫn là không có gì.
  - Trên `pinwheel` tĩnh, **8/11 lần xoá slice P giải mã ra trùng khít từng pixel** (MAE = 0,000). Đó là cơ chế concealment bị bắt quả tang: nó chép dải cùng vị trí từ frame trước, và khi không có gì chuyển động thì bản chép *là* đáp án đúng.
  - Suýt sai lần nữa: script ban đầu chạy 60 picture, nên đợt hỏng của IDR (`30..59`) kết thúc **đúng lúc bản ghi hết**. Cái dấu "kết thúc tại keyframe" khi đó là *giả định*, không phải quan sát. Đổi mặc định sang 90 picture (3 GOP) để keyframe cứu nó — picture 60 — nằm trong bản ghi. Đúng cái bẫy "episode bị cắt cụt" ở trên, lần thứ hai.
  - Và một lần nữa nữa: tôi viết vào tài liệu "chạy hai lần cho cùng một bảng". Đối chiếu hai lần chạy `pinwheel` thật: 0,226 rồi 0,225. Vì script **encode lại mỗi lần**, mà `x264enc` không tái lập được từng bit — đúng cái điều chính tài liệu đó nói ở mục trên. Xác định lại cho đúng: *cho trước một bitstream* thì phép xoá slice là tất định; qua các lần encode thì chữ số thập phân thứ ba dao động. Không kết luận nào ở đây dựa vào chữ số thứ ba.
  - Sai sót lúc chạy: `idr-vs-p.sh` nhận `SRC_EXTRA` qua **tham số vị trí thứ 2**, còn `sender.sh`/`make-stream.sh` nhận qua **biến môi trường**. Tôi gọi `SRC_EXTRA="..." bash idr-vs-p.sh zone-plate` → `$2` rỗng ghi đè, chạy nhầm `zone-plate` mặc định (tĩnh) và suýt kết luận ngược. Đã cho script nhận cả hai kiểu.
- Còn mở (đã thu hẹp): vậy **cái gì** làm `pinwheel` vỡ ở 2% loss? Giả thuyết: ở 0,15% thì ~1 gói mất mỗi 2 GOP nên dải hỏng luôn được chép từ hàng xóm *đúng*; ở 2% thì ~1 gói mỗi 6 picture, nhiều slice trên nhiều frame liên tiếp, và cái frame trước — thứ concealment chép từ đó — tự nó đã sai. Ảnh tĩnh thôi không còn là bộ dự đoán tốt cho chính nó. **Chưa đo → tài liệu ghi là giả thuyết.**
- `demo.mp4` cuối cùng dùng `zone-plate kx2=20 ky2=20 kt2=1` (72,9% pixel động): 88 gói mất, hình vỡ rõ, hồi phục tại keyframe.
- Lặt vặt: `measure-latency.sh` tự định nghĩa lại `ENC_TUNED` dù `common.sh` nói rõ "để ở đây cho hai script khỏi trôi lệch nhau" → xoá. `packet-loss.sh` vẫn in ra con số "nửa GOP = 15" mà chính `packet-loss.md` bác bỏ → sửa. `latency.md` bảo trace log nằm "cạnh file này" nhưng `.gitignore` loại chúng → nói thật.
- Bài học môi trường: `fs.protected_regular=2` (mặc định Ubuntu 22.04) khiến **root không ghi được** file của user khác trong `/tmp` sticky. Một `/tmp/e` cũ do lần chạy non-root để lại làm **toàn bộ** bộ test báo FAIL. Dùng `mktemp`.

**2026-07-10 — Ngày 2, MAVLink gateway** — connection + watchdog + telemetry + commands + MQTT, test end-to-end với mock.

- **T2.1 SITL: suýt bỏ, rồi dựng được.** Clone ArduPilot + submodule (>1 GB) trên mạng ~150 KB/s chập chờn cứ `curl 28: too slow` rồi hỏng. Đúng plan, tôi sang fallback `mock_fc.py` và viết xong toàn bộ gateway. Nhưng để clone chạy nền — mạng hồi phục, tải hết 1,5 GB, `waf copter` build `arducopter` (5,7 MB) trong 67 giây. Vậy là **có SITL thật để kiểm chứng**. Quyết định: kiểm chứng với SITL thật trước khi động vào CV, vì kết quả thật phải quyết định câu chữ, không phải cái mock của tôi.
- **★ SITL bắt hai lỗi mà mock giấu kín — đây là lý do phải test với implementation độc lập.**
  1. **ArduPilot không stream telemetry nếu không hỏi.** Nó chỉ gửi HEARTBEAT, im lặng với ATTITUDE/POSITION/SYS_STATUS cho tới khi GCS gửi `REQUEST_DATA_STREAM`. Mock của tôi stream tất cả từ gói đầu, nên gateway *chưa từng cần hỏi* — và với SITL thì mọi cột telemetry về null, `_wait_until_armable` treo vô tận. Sửa: `connection.py` request stream ngay khi connect.
  2. **Bit sức khoẻ sensor xanh *trước* khi arm được thật.** Mock bật bit rồi accept arm luôn; SITL bật cùng bit đó vài giây *trước* khi GPS có 3D fix và EKF set origin, và trả `MAV_RESULT_FAILED` trong khoảng đó. Arm một phát ăn ngay là thua cuộc đua. Sửa: chờ GPS 3D fix (`GPS_RAW_INT.fix_type>=3`) rồi **retry arm** xuyên qua cửa sổ pre-arm, đọc luôn dòng `PreArm:` của FC nếu mãi không được.
  - Cả hai lỗi này mock **không bao giờ** làm tôi phát hiện, vì mock chỉ từ chối theo đúng những gì tôi đã lường trước. Đó chính xác là điểm tôi ghi trong `mavlink/README.md` từ đầu: mock và gateway chung một cách hiểu spec. SITL là cách hiểu độc lập.
  - Sau khi sửa: `takeoff 10` với SITL thật → arm + leo `0 → 5,6 → 10,0 m`, giữ ở 10 m, **hai lần khởi động lạnh đều rc=0**. Mock vẫn chạy (đã thêm `GPS_RAW_INT` cho mock để hai đường dùng chung cổng GPS-fix). Watchdog cũng thử với SITL: giết tiến trình SITL giữa chừng → `LINK LOST` sau 3,3 s.
- **`mock_fc.py` không chỉ là "phát telemetry giả".** Nó *trả lời lệnh*: nhận `COMMAND_LONG` thì gửi `COMMAND_ACK`, và **thực thi đúng luật thứ tự của ArduPilot** — từ chối arm khi chưa GUIDED, từ chối takeoff khi chưa arm, có giai đoạn "khởi động" trước khi báo sensor khoẻ. Nếu mock dễ dãi thì gateway coi như không được test phần khó nhất.
- **Watchdog viết như máy trạng thái, không phải thread.** `feed()` mỗi heartbeat, `check()` mỗi vòng lặp; callback `on_lost`/`on_restored` bắn đúng một lần mỗi cạnh. Không thread → không lock → không race. Clock **tiêm được**, nên test 3 giây failsafe không cần `sleep 3` — `tests/test_watchdog.py` 7/7 pass, gồm cả biên (gap *đúng bằng* timeout thì **chưa** mất) và đảm bảo bắn-một-lần.
- **Cái bẫy telemetry là scaling, không phải parsing.** MAVLink gửi số nguyên đã scale, sai thì **không báo lỗi** mà log ra rác trông hợp lý. Mỗi field ghi rõ đơn vị gốc: `lat` degE7→độ, `alt` mm→m, `roll` rad→độ, `voltage` mV→V, `battery_remaining=-1` là "không biết"→null. Verify: lat −35,363262, alt 584 m MSL, rel_alt bò 0→10, yaw ra độ, pin 12,589 V.
- **Lệnh phải đọc ACK, và đọc đúng cái ACK của mình.** Khớp `COMMAND_ACK.command` với lệnh vừa gửi, không lấy "ACK kế tiếp" — vì trên dây còn telemetry và có thể nhiều lệnh đang bay. `guided_takeoff` chạy đúng thứ tự: chờ GPS 3D fix → GUIDED → arm (có retry) → takeoff, dừng ngay ở bước đầu bị từ chối. Với mock: arm-trước-GUIDED → `TEMPORARILY_REJECTED` (exit 1). Với SITL thật: takeoff 10 → leo tới 10 m.
- **Về cái mock:** vẫn giữ, nhưng đúng vai của nó — công cụ lặp nhanh, không phải bằng chứng. Bằng chứng end-to-end giờ là SITL thật. Điều tôi ghi từ đầu ("mock và gateway chung một cách hiểu spec, không phải kiểm chứng độc lập") hoá ra không chỉ là lời rào đón lịch sự — nó đúng theo nghĩa đen, SITL bắt được hai lỗi thật.

---

## Số liệu đã đo

Điền dần, đây là thứ đi thẳng lên CV.

| Chỉ số | Giá trị | Đo bằng cách nào |
|---|---|---|
| Latency — default | **2288 ms** (median) | `GST_TRACERS="latency(flags=pipeline+element)"` |
| Latency — tuned | **7.8 ms** (median) | như trên, `scripts/measure-latency.sh` |
| — trong đó x264enc | 2067 ms → 4.2 ms | element-latency của `x264enc0` |
| — trong đó jitter buffer | 218 ms → 0.8 ms | element-latency của `rtpjitterbuffer0` |
| Chi phí `rc-lookahead=40` | 39.4 frame | ép `threads=1`, quét lookahead |
| Chi phí frame threading | ~1 frame/luồng (28 frame ở 16 lõi) | ép `rc-lookahead=0`, quét threads |
| Kích thước frame I420 | 1 382 400 B = 1280×720×1.5 | `receiver.cpp`, `gst_buffer_map` |
| Rò bộ nhớ theo frame | **0** (16 448 B hằng số, cấp phát trước `main`) | valgrind ở 50 và 173 frame |
| Slice mỗi picture | **11** (do sliced threads) | `scripts/gop-stats.sh` |
| Khoảng cách IDR | đúng 30 picture (min=max) | như trên, quét NAL Annex-B |
| Tỉ lệ I/P | 2,8× (smpte) · 3,2× (ball) · **15,0×** (pinwheel) · 8,4× (zone-plate) | như trên |
| Gói thuộc keyframe | **15%** tổng số gói | như trên, mô hình FU-A mtu=1400 |
| Đợt hỏng kết thúc tại IDR | **29/29** (4 pattern); lần 2: 29/31 | `scripts/pattern-damage.sh`, bitstream đóng băng |
| — như trên, bỏ netem, tự chọn gói xoá | **36/36**, liền mạch, không lệch 1 frame | `scripts/idr-vs-p.sh`, xoá từng slice NAL |
| Mất slice IDR so với slice P | **5,8×** (10,69 vs 1,85 /255 tại frame trúng) | như trên, `zone-plate` động |
| — phần do lỗi tích luỹ thêm | chỉ **+3%** so với sai lệch tại frame trúng | như trên, cột `impact` vs `peak` |
| Mất slice P trên ảnh tĩnh | **8/11** lần trùng khít từng pixel (MAE 0,000) | như trên, `pinwheel` |
| Thiệt hại mỗi GOP bị trúng | **24,1 picture ≈ 803 ms** (mô hình: 20,1) | `scripts/frame-diff.sh` |
| Cờ `discont`/`CORRUPTED` ở 20% loss | **0 / 0** (decoder che lỗi im lặng) | quét loss 0→20% |
| `latency=0`, jitter ±5 ms, **0 gói mất** | chỉ **67/300** picture | control `netem delay 20ms 5ms` |
| `latency=200`, cùng điều kiện | **270–300/300** picture | 3 lần chạy |
| `wait-for-keyframe` ở 2% loss | **11/300** picture được hiển thị | `receiver --wait-for-keyframe` |
| Pixel động giữa 2 frame | pinwheel **0,0%** · ball 2,0% · smpte 5,8% · zone-plate 72,9% | `scripts/pattern-damage.sh` |
| Biên độ hỏng (median, 0,15% loss) | pinwheel **0,01** → zone-plate **4,22** (/255) | như trên; picture sai: 110–155/600 ở *mọi* pattern |
| "worst picture" giữa 2 lần chạy | 2,2 rồi **12,1** — cực đại không phải thống kê | cùng một lệnh, `smpte`, 2% loss |
| **MAVLink** — kiểm chứng với SITL thật | `takeoff 10` → **arm + leo tới 10 m**, 2/2 lần khởi động lạnh rc=0 | ArduCopter SITL, tcp:5760 |
| — watchdog báo LINK LOST (giết SITL) | **3,0–3,5 s** (ngưỡng 3,0 s + nhịp kiểm ≤0,5 s) | `gateway monitor`, kill SITL |
| — unit test failsafe | **7/7** pass, clock giả (không `sleep`) | `tests/test_watchdog.py` |
| — telemetry từ SITL thật | **572 dòng/lần**, scale SI đúng (lat −35,363262, alt 584,09 m) | `gateway monitor`, SITL |
| — arm trước GUIDED | bị từ chối `TEMPORARILY_REJECTED` (exit 1) | `gateway arm`, mock |
| — 2 lỗi SITL bắt được mà mock giấu | thiếu `REQUEST_DATA_STREAM`; đua pre-arm | đã sửa `connection.py`, `commands.py` |
