Đề tài: Xây dựng REST API phân tán sử dụng PostgreSQL và Flask (Eventual Consistency)

## 1. Kiến trúc tổng quan
Bạn chạy 3 instance PostgreSQL cục bộ:
* Master (port 5432) – chứa dữ liệu tổng hợp + các hàm đồng bộ (FDW & mapping)
* Shard Public (port 5433) – dữ liệu sinh viên/trường công
* Shard Private (port 5434) – dữ liệu sinh viên/trường tư

Ứng dụng Flask (app.py) kết nối trực tiếp cả 3 instance. Khi đăng ký ở shard, bản ghi được đồng bộ (remap) về master qua hàm `sync_registrations_remapped()` trong `mapping_method.sql`.

## 2. Chuẩn bị môi trường
### 2.1 Cài PostgreSQL
Tải bộ cài (Windows) từ https://www.postgresql.org/download/ và cài bình thường (ví dụ PostgreSQL 15). Mặc định sẽ tạo cluster đầu tiên ở port 5432.

### 2.2 Tạo thêm 2 cluster (5433 & 5434)
Mở PowerShell với quyền Administrator, tạo thư mục dữ liệu và initdb (chỉnh phiên bản, đường dẫn phù hợp):
```powershell
mkdir C:\pgdata\5433
mkdir C:\pgdata\5434
"C:\Program Files\PostgreSQL\15\bin\initdb.exe" -D C:\pgdata\5433 -U postgres -W -E UTF8
"C:\Program Files\PostgreSQL\15\bin\initdb.exe" -D C:\pgdata\5434 -U postgres -W -E UTF8
```
Khi hỏi mật khẩu, bạn có thể đặt:
* 5432: `7363728258` (phù hợp với `app.py`)
* 5433 & 5434: `12` (phù hợp với `app.py` & `mapping_method.sql`)

> Nếu muốn dùng mật khẩu khác, sửa lại trong `app.py` (hàm `get_db_conn`) và trong `mapping_method.sql` (các dòng `CREATE USER MAPPING ... password`).

### 2.3 Chỉnh cổng và listen
Mở file `postgresql.conf` của từng cluster:
* 5432: thường ở `C:\Program Files\PostgreSQL\15\data\postgresql.conf`
* 5433: `C:\pgdata\5433\postgresql.conf`
* 5434: `C:\pgdata\5434\postgresql.conf`

Thiết lập (hoặc đảm bảo) các dòng sau:
```
listen_addresses = '*'
port = 5432   # (5432 | 5433 | 5434 tương ứng mỗi cluster)
```

### 2.4 Chỉnh quyền truy cập pg_hba.conf
Mở `pg_hba.conf` của mỗi cluster, thêm (đặt gần cuối để override):
```
host all all 127.0.0.1/32 md5
host all all ::1/128 md5
```
Nếu bạn cần kết nối từ máy khác, có thể thêm:
```
host all all 0.0.0.0/0 md5
```
> Chỉ dùng 0.0.0.0/0 trong môi trường học tập/demo, không khuyến nghị production.

Sau khi chỉnh `postgresql.conf` & `pg_hba.conf`, khởi động (hoặc restart) các cluster.

### 2.5 Đăng ký cluster 5433 & 5434 thành Windows Service (tuỳ chọn)
```powershell
"C:\Program Files\PostgreSQL\15\bin\pg_ctl.exe" register -N "postgresql-15-5433" -D "C:\pgdata\5433" -o "-p 5433"
"C:\Program Files\PostgreSQL\15\bin\pg_ctl.exe" register -N "postgresql-15-5434" -D "C:\pgdata\5434" -o "-p 5434"
Start-Service postgresql-15-5433
Start-Service postgresql-15-5434
```

Hoặc chạy tạm thời:
```powershell
"C:\Program Files\PostgreSQL\15\bin\pg_ctl.exe" -D C:\pgdata\5433 -o "-p 5433" start
"C:\Program Files\PostgreSQL\15\bin\pg_ctl.exe" -D C:\pgdata\5434 -o "-p 5434" start
```

### 2.6 Cấu hình tường lửa Windows (nếu cần truy cập ngoài localhost)
```powershell
New-NetFirewallRule -DisplayName "Postgres5432" -Direction Inbound -Protocol TCP -LocalPort 5432 -Action Allow
New-NetFirewallRule -DisplayName "Postgres5433" -Direction Inbound -Protocol TCP -LocalPort 5433 -Action Allow
New-NetFirewallRule -DisplayName "Postgres5434" -Direction Inbound -Protocol TCP -LocalPort 5434 -Action Allow
```

## 3. Khôi phục schema và dữ liệu mẫu
Mở psql cho từng cổng.

### 3.1 Master 5432
```powershell
"C:\Program Files\PostgreSQL\15\bin\psql.exe" -h localhost -p 5432 -U postgres -f sql\script_5432.sql
```

### 3.2 Shard 5433
File `sql\script_5433.sql` cần chứa dữ liệu shard public (tương tự `script_5434.sql` nhưng cho nhóm public). Nếu chưa có, tạo file dựa trên subset public từ `script_5432.sql` (các trường u_id 1..10) rồi chạy:
```powershell
"C:\Program Files\PostgreSQL\15\bin\psql.exe" -h localhost -p 5433 -U postgres -f sql\script_5433.sql
```

### 3.3 Shard 5434 (Private)
```powershell
"C:\Program Files\PostgreSQL\15\bin\psql.exe" -h localhost -p 5434 -U postgres -f sql\script_5434.sql
```

### 3.4 Thiết lập FDW + Mapping trên master
Chạy file `mapping_method.sql` trên 5432:
```powershell
"C:\Program Files\PostgreSQL\15\bin\psql.exe" -h localhost -p 5432 -U postgres -f sql\mapping_method.sql
```

> Script này tạo foreign servers `fdw_5433`, `fdw_5434`, các bảng foreign (`students_5433`, `sections_5433`, ...), bảng mapping `students_map`, `sections_map` và các hàm sync: `sync_students_from_shard`, `sync_sections_from_shard`, `sync_registrations_remapped`, `sync_all_remapped`.

## 4. Cài đặt Python & thư viện
Tạo virtual environment (khuyến khích):
```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install --upgrade pip
pip install flask psycopg2-binary
```

Nếu dùng `psycopg2` bản nguồn bị lỗi build, giữ `psycopg2-binary` là đủ cho dev.

## 5. Chạy ứng dụng
```powershell
python app.py
```
Mặc định Flask chạy tại http://127.0.0.1:5000/

Mở trình duyệt: nhập tên hoặc id student -> chọn section -> Đăng Ký.

## 6. Cơ chế đồng bộ
1. Ghi đăng ký mới vào shard (5433 hoặc 5434) dựa trên `u_id` của student.
2. Gọi hàm `sync_registrations_remapped()` trên master:
	 * Đồng bộ trước students & sections (mapping) nếu thiếu.
	 * Remap `stno` & `sec_no` sang master thông qua `students_map` & `sections_map`.
	 * Insert vào `registrations` master với `synced_at` = thời điểm sync.
	 * Đánh dấu `synced_at` trên bản ghi shard để tránh insert lại.

## 7. Kiểm tra nhanh
Trong psql trên 5432:
```sql
SELECT sync_registrations_remapped();
SELECT reg_id, stno, sec_no, created_at, synced_at FROM registrations ORDER BY reg_id DESC LIMIT 10;
```

## 8. Tuỳ chỉnh & Lưu ý
* Đổi mật khẩu: sửa cả `app.py` và `mapping_method.sql` (USER MAPPING).
* Nếu thêm shard mới, nhân bản logic: tạo FDW server + foreign tables + mở rộng hàm sync.
* Tránh để `0.0.0.0/0` trên production.
* Có thể thêm UNIQUE (stno, sec_no) ở master để đảm bảo không trùng: `ALTER TABLE registrations ADD CONSTRAINT uniq_master_reg UNIQUE (stno, sec_no);`

## 9. Sự cố thường gặp
| Vấn đề | Nguyên nhân | Cách khắc phục |
|--------|-------------|----------------|
| Không sync được (lỗi FDW password) | Sai password user mapping | Sửa `CREATE USER MAPPING` và chạy lại script hoặc `ALTER USER MAPPING` |
| Trùng section tạo thêm id 28,29,30 | Business key chưa phù hợp | Đã sửa: bỏ `ins_id` khỏi business key trong `sync_sections_from_shard` |
| synced_at NULL trên master | Chưa cập nhật hàm insert | Đã cập nhật: master chèn `synced_at` bằng `sync_ts` |
| psycopg2 build error | Thiếu lib build trên Windows | Dùng `psycopg2-binary` |

## 10. Lệnh hữu ích khác
```powershell
# Restart nhanh cluster 5433
"C:\Program Files\PostgreSQL\15\bin\pg_ctl.exe" -D C:\pgdata\5433 restart

# Kiểm tra kết nối FDW (trên 5432)
psql -h localhost -p 5432 -U postgres -c "SELECT COUNT(*) FROM students_5433;"
```

## 11. Cấu trúc thư mục chính
```
app.py
templates/index.html
sql/
	script_5432.sql
	script_5433.sql  (tự tạo nếu chưa có)
	script_5434.sql
	mapping_method.sql
```

---
Sau khi hoàn thành các bước trên bạn có thể thực hiện đăng ký và quan sát độ trễ eventual consistency qua cột `synced_at` và `latency` trong UI (nút "Xem Danh Sách").

Chúc bạn thành công!
