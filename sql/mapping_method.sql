-- Bật extension cần thiết
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- NOTE: Trước khi chạy bạn cần đảm bảo master (5432) có thể kết nối tới replicas (5433,5434)
-- Nếu cần, thay password trong CREATE USER MAPPING phía dưới cho phù hợp môi trường.

-- Bảng student master (nếu bạn muốn giữ bản sao tập trung)
CREATE TABLE IF NOT EXISTS students_master (
  master_stno SERIAL PRIMARY KEY,
  u_id INTEGER,
  col_id INTEGER,
  dep_id INTEGER,
  fname VARCHAR(30),
  mname VARCHAR(30),
  lname VARCHAR(30),
  st_address VARCHAR(60),
  gender CHAR(1),
  prog_degree INTEGER,
  dob DATE
);

-- Bảng ánh xạ: lưu thông tin stno trên từng shard -> master_stno
CREATE TABLE IF NOT EXISTS students_map (
  shard_name TEXT NOT NULL,
  shard_stno INTEGER NOT NULL,
  master_stno INTEGER NOT NULL REFERENCES students_master(master_stno),
  created_at TIMESTAMP DEFAULT now(),
  UNIQUE (shard_name, shard_stno)
);

-- Thiết lập FDW servers và foreign tables -> master sẽ truy vấn trực tiếp từ replicas
-- Tạo server FDW cho 5433 và 5434 (thực thi trên master)
CREATE SERVER IF NOT EXISTS fdw_5433 FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'localhost', port '5433', dbname 'enrollment_db');
CREATE SERVER IF NOT EXISTS fdw_5434 FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host 'localhost', port '5434', dbname 'enrollment_db');

-- User mapping (thay password nếu cần)
CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER fdw_5433 OPTIONS (user 'postgres', password '12');
CREATE USER MAPPING IF NOT EXISTS FOR CURRENT_USER SERVER fdw_5434 OPTIONS (user 'postgres', password '12');

-- Tạo foreign table đại diện cho bảng students trên từng shard
CREATE FOREIGN TABLE IF NOT EXISTS students_5433 (
  stno INTEGER,
  u_id INTEGER,
  col_id INTEGER,
  dep_id INTEGER,
  fname VARCHAR(30),
  mname VARCHAR(30),
  lname VARCHAR(30),
  st_address VARCHAR(60),
  gender CHAR(1),
  prog_degree INTEGER,
  dob DATE
) SERVER fdw_5433 OPTIONS (schema_name 'public', table_name 'students');

CREATE FOREIGN TABLE IF NOT EXISTS students_5434 (
  stno INTEGER,
  u_id INTEGER,
  col_id INTEGER,
  dep_id INTEGER,
  fname VARCHAR(30),
  mname VARCHAR(30),
  lname VARCHAR(30),
  st_address VARCHAR(60),
  gender CHAR(1),
  prog_degree INTEGER,
  dob DATE
) SERVER fdw_5434 OPTIONS (schema_name 'public', table_name 'students');

-- Tạo foreign table cho registrations trên từng shard (để sync)
CREATE FOREIGN TABLE IF NOT EXISTS registrations_5433 (
  reg_id INTEGER,
  stno INTEGER,
  sec_no INTEGER,
  created_at TIMESTAMP,
  synced_at TIMESTAMP,
  mark FLOAT
) SERVER fdw_5433 OPTIONS (schema_name 'public', table_name 'registrations');

CREATE FOREIGN TABLE IF NOT EXISTS registrations_5434 (
  reg_id INTEGER,
  stno INTEGER,
  sec_no INTEGER,
  created_at TIMESTAMP,
  synced_at TIMESTAMP,
  mark FLOAT
) SERVER fdw_5434 OPTIONS (schema_name 'public', table_name 'registrations');

-- Foreign tables cho sections trên từng shard
CREATE FOREIGN TABLE IF NOT EXISTS sections_5433 (
  sec_no INTEGER,
  year INTEGER,
  semester VARCHAR(10),
  time VARCHAR(20),
  hall VARCHAR(20),
  c_no VARCHAR(10),
  ins_id INTEGER,
  capacity INTEGER
) SERVER fdw_5433 OPTIONS (schema_name 'public', table_name 'sections');

CREATE FOREIGN TABLE IF NOT EXISTS sections_5434 (
  sec_no INTEGER,
  year INTEGER,
  semester VARCHAR(10),
  time VARCHAR(20),
  hall VARCHAR(20),
  c_no VARCHAR(10),
  ins_id INTEGER,
  capacity INTEGER
) SERVER fdw_5434 OPTIONS (schema_name 'public', table_name 'sections');

-- Bảng mapping cho sections để tránh đụng sec_no giữa các shard
CREATE TABLE IF NOT EXISTS sections_map (
  shard_name TEXT NOT NULL,
  shard_sec_no INTEGER NOT NULL,
  master_sec_no INTEGER NOT NULL REFERENCES sections(sec_no),
  created_at TIMESTAMP DEFAULT now(),
  UNIQUE (shard_name, shard_sec_no)
);

-- Đồng bộ sections từ shard -> master với mapping tránh trùng khóa
-- Đồng bộ sections từ shard -> master với mapping tránh trùng khóa
CREATE OR REPLACE FUNCTION sync_sections_from_shard(shard TEXT) RETURNS INTEGER AS $$
DECLARE
  r RECORD;
  inserted_cnt INTEGER := 0;
  tbl TEXT;
  master_id INTEGER;
BEGIN
  IF shard NOT IN ('5433','5434') THEN
    RAISE EXCEPTION 'Unknown shard %', shard;
  END IF;
  tbl := 'sections_' || shard;
  FOR r IN EXECUTE format('SELECT sec_no, year, semester, time, hall, c_no, ins_id, capacity FROM %I', tbl) LOOP
    -- Kiểm tra mapping hiện có
    SELECT master_sec_no INTO master_id FROM sections_map WHERE shard_name = shard AND shard_sec_no = r.sec_no;
    IF master_id IS NULL THEN
      -- Tìm section tồn tại theo business key mới (chỉ year, semester, c_no)
      SELECT sec_no INTO master_id FROM sections
        WHERE year = r.year AND semester = r.semester AND c_no = r.c_no
        ORDER BY sec_no
        LIMIT 1;
      IF master_id IS NULL THEN
        -- Chưa có -> insert mới (không cố giữ nguyên id để tránh va chạm)
        -- Lưu ý: ins_id trên shard có thể không khớp instructor trên master; chỉ nên insert khi thật sự là section mới.
        RAISE NOTICE 'Inserting new section for shard % sec_no % with business key: year=%, semester=%, c_no=%', shard, r.sec_no, r.year, r.semester, r.c_no;
        INSERT INTO sections(year, semester, time, hall, c_no, ins_id, capacity)
        VALUES (r.year, r.semester, r.time, r.hall, r.c_no, r.ins_id, r.capacity)
        RETURNING sec_no INTO master_id;
        inserted_cnt := inserted_cnt + 1;
      ELSE
        -- Đã có section tương đương -> cập nhật capacity/time/hall (KHÔNG cập nhật ins_id để tránh gán sai instructor)
        UPDATE sections SET capacity = r.capacity, time = r.time, hall = r.hall
        WHERE sec_no = master_id;
        RAISE NOTICE 'Matched and updated existing section % for shard % sec_no %', master_id, shard, r.sec_no;
      END IF;
      INSERT INTO sections_map(shard_name, shard_sec_no, master_sec_no) VALUES (shard, r.sec_no, master_id)
      ON CONFLICT (shard_name, shard_sec_no) DO NOTHING; -- idempotent
    ELSE
      -- Mapping tồn tại -> chỉ cập nhật các trường có thể thay đổi an toàn (capacity/time/hall). Bỏ qua ins_id.
      UPDATE sections SET time = r.time, hall = r.hall, capacity = r.capacity
      WHERE sec_no = master_id;
      RAISE NOTICE 'Updated mapped section % for shard % sec_no %', master_id, shard, r.sec_no;
    END IF;
  END LOOP;
  RETURN inserted_cnt;
END;
$$ LANGUAGE plpgsql;

-- Hàm đồng bộ students từ một shard (KHÔNG phụ thuộc cột synced_at trên shard để tránh lỗi nếu thiếu cột)
CREATE OR REPLACE FUNCTION sync_students_from_shard(shard TEXT) RETURNS INTEGER AS $$
DECLARE
  r RECORD;
  m_master INTEGER;
  tbl TEXT;
  inserted_count INTEGER := 0;
BEGIN
  IF shard NOT IN ('5433','5434') THEN
    RAISE EXCEPTION 'Unknown shard %', shard;
  END IF;
  tbl := 'students_' || shard;
  FOR r IN EXECUTE format('SELECT stno, u_id, col_id, dep_id, fname, mname, lname, st_address, gender, prog_degree, dob FROM %I', tbl) LOOP
    SELECT master_stno INTO m_master FROM students_map WHERE shard_name = shard AND shard_stno = r.stno;
    IF m_master IS NULL THEN
      INSERT INTO students_master(u_id, col_id, dep_id, fname, mname, lname, st_address, gender, prog_degree, dob)
      VALUES (r.u_id, r.col_id, r.dep_id, r.fname, r.mname, r.lname, r.st_address, r.gender, r.prog_degree, r.dob)
      RETURNING master_stno INTO m_master;
      INSERT INTO students_map(shard_name, shard_stno, master_stno) VALUES (shard, r.stno, m_master);
      inserted_count := inserted_count + 1;
    ELSE
      -- Có thể cập nhật thông tin nếu thay đổi
      UPDATE students_master SET u_id=r.u_id, col_id=r.col_id, dep_id=r.dep_id, fname=r.fname, mname=r.mname, lname=r.lname, st_address=r.st_address, gender=r.gender, prog_degree=r.prog_degree, dob=r.dob
      WHERE master_stno = m_master;
    END IF;
  END LOOP;
  RETURN inserted_count;
END;
$$ LANGUAGE plpgsql;

-- Hàm đồng bộ registrations với remap stno, tránh duplicate bằng điều kiện NOT EXISTS (giả sử master có UNIQUE(stno,sec_no))
CREATE OR REPLACE FUNCTION sync_registrations_remapped() RETURNS INTEGER AS $$
DECLARE
  inserted_cnt INTEGER := 0;
  rcount INTEGER;
BEGIN
  -- Đảm bảo sinh mapping trước
  PERFORM sync_students_from_shard('5433');
  PERFORM sync_students_from_shard('5434');
  PERFORM sync_sections_from_shard('5433');
  PERFORM sync_sections_from_shard('5434');

  -- 5433
  INSERT INTO registrations (stno, sec_no, created_at, mark)
  SELECT sm.master_stno, secmap.master_sec_no, r.created_at, r.mark
  FROM registrations_5433 r
  JOIN students_map sm ON sm.shard_name='5433' AND sm.shard_stno = r.stno
  JOIN sections_map secmap ON secmap.shard_name='5433' AND secmap.shard_sec_no = r.sec_no
  LEFT JOIN registrations tgt ON tgt.stno = sm.master_stno AND tgt.sec_no = secmap.master_sec_no
  WHERE r.synced_at IS NULL AND tgt.reg_id IS NULL;
  GET DIAGNOSTICS rcount = ROW_COUNT;
  inserted_cnt := inserted_cnt + rcount;
  -- update synced_at remote qua foreign table
  UPDATE registrations_5433 SET synced_at = now() WHERE synced_at IS NULL;

  -- 5434
  INSERT INTO registrations (stno, sec_no, created_at, mark)
  SELECT sm.master_stno, secmap.master_sec_no, r.created_at, r.mark
  FROM registrations_5434 r
  JOIN students_map sm ON sm.shard_name='5434' AND sm.shard_stno = r.stno
  JOIN sections_map secmap ON secmap.shard_name='5434' AND secmap.shard_sec_no = r.sec_no
  LEFT JOIN registrations tgt ON tgt.stno = sm.master_stno AND tgt.sec_no = secmap.master_sec_no
  WHERE r.synced_at IS NULL AND tgt.reg_id IS NULL;
  GET DIAGNOSTICS rcount = ROW_COUNT;
  inserted_cnt := inserted_cnt + rcount;
  UPDATE registrations_5434 SET synced_at = now() WHERE synced_at IS NULL;

  RETURN inserted_cnt;
END;
$$ LANGUAGE plpgsql;

-- Wrapper sync all (gọi sync students rồi registrations)
CREATE OR REPLACE FUNCTION sync_all_remapped() RETURNS INTEGER AS $$
DECLARE total INTEGER; BEGIN
  PERFORM sync_students_from_shard('5433');
  PERFORM sync_students_from_shard('5434');
  PERFORM sync_sections_from_shard('5433');
  PERFORM sync_sections_from_shard('5434');
  SELECT sync_registrations_remapped() INTO total;
  RETURN total;
END; $$ LANGUAGE plpgsql;

-- (ĐÃ LOẠI BỎ các phiên bản hàm trùng lặp phía trên để tránh nhầm lẫn)

-- Lưu ý: chỉnh lại chuỗi kết nối (password) cho phù hợp môi trường của bạn.
-- Sau khi chạy file này trên master (5432), bạn có thể gọi: SELECT sync_all_remapped();
