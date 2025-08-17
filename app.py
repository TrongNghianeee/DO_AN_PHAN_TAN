from flask import Flask, request, jsonify, render_template
import psycopg2

app = Flask(__name__)

# Hàm kết nối DB với password khác nhau dựa trên port
def get_db_conn(port):
    if port == 5432:
        password = '7363728258'
    else:
        password = '12'
    return psycopg2.connect(
        host='localhost',
        port=port,
        dbname='enrollment_db',
        user='postgres',
        password=password
    )


# Helpers to find student and current term
def find_student(stno=None, q=None, fullname=None):
    """
    Search students by stno or text query across public and private shards.
    Returns first matching student dict or list (for q).
    """
    shards = [5433, 5434]
    results = []
    for p in shards:
        conn = None
        try:
            conn = get_db_conn(p)
            cur = conn.cursor()
            if stno is not None:
                cur.execute("SELECT stno, fname, mname, lname, u_id FROM students WHERE stno = %s", (stno,))
                row = cur.fetchone()
                if row:
                    # If fullname provided, disambiguate by matching combined name
                    combined = f"{row[1] or ''} {row[2] or ''} {row[3] or ''}".strip()
                    entry = {'stno': row[0], 'fname': row[1], 'mname': row[2], 'lname': row[3], 'u_id': row[4], 'fullname': combined}
                    if fullname:
                        if fullname.strip().lower() == combined.lower() or fullname.strip().lower() in combined.lower():
                            return entry
                        # otherwise this shard's student doesn't match requested full name; continue to next shard
                    else:
                        # collect possible matches when stno provided but fullname not given
                        results.append(entry)
            elif q is not None:
                # search by id text or name parts
                pattern = f"%{q}%"
                cur.execute(
                    "SELECT stno, fname, mname, lname, u_id FROM students WHERE (fname || ' ' || mname || ' ' || lname) ILIKE %s OR CAST(stno AS TEXT) ILIKE %s LIMIT 50",
                    (pattern, pattern)
                )
                rows = cur.fetchall()
                for r in rows:
                    display = f"{r[1]} {r[2]} {r[3]} (id={r[0]})"
                    results.append({'stno': r[0], 'display': display, 'u_id': r[4]})
        except Exception:
            # ignore shard errors for search - return what we can
            pass
        finally:
            if conn:
                conn.close()
    if q is not None:
        return results
    # if stno search produced multiple candidates, return list; if single, return dict
    if results:
        if len(results) == 1:
            return results[0]
        return results
    return None


def _taken_sections_from_shards(shard_stno, year, semester, shard_hint=None):
    """Collect sec_no already registered for this student (consider mapping master_stno)."""
    taken = set()
    master_stno = None
    # Try mapping (if mapping_method.sql executed)
    try:
        mconn = get_db_conn(5432)
        mcur = mconn.cursor()
        if shard_hint:
            mcur.execute("SELECT master_stno FROM students_map WHERE shard_name=%s AND shard_stno=%s", (str(shard_hint), shard_stno))
        else:
            mcur.execute("SELECT master_stno FROM students_map WHERE shard_stno=%s LIMIT 1", (shard_stno,))
        row = mcur.fetchone()
        if row:
            master_stno = row[0]
        if master_stno:
            mcur.execute(
                "SELECT r.sec_no FROM registrations r JOIN sections s ON r.sec_no = s.sec_no WHERE r.stno = %s AND s.year = %s AND s.semester = %s",
                (master_stno, year, semester)
            )
            for r in mcur.fetchall():
                taken.add(r[0])
    except Exception:
        pass
    finally:
        try:
            mcur.close(); mconn.close()
        except Exception:
            pass

    # shards side (use provided shard_hint if any, else both)
    shards = [int(shard_hint)] if shard_hint else [5433, 5434]
    shard_sec_nos = set()
    for p in shards:
        try:
            sconn = get_db_conn(p)
            scur = sconn.cursor()
            scur.execute("SELECT sec_no FROM registrations WHERE stno = %s", (shard_stno,))
            for r in scur.fetchall():
                shard_sec_nos.add(r[0])
        except Exception:
            pass
        finally:
            try:
                scur.close(); sconn.close()
            except Exception:
                pass

    if shard_sec_nos:
        try:
            mconn = get_db_conn(5432)
            mcur = mconn.cursor()
            mcur.execute("SELECT sec_no FROM sections WHERE sec_no = ANY(%s) AND year = %s AND semester = %s", (list(shard_sec_nos), year, semester))
            for r in mcur.fetchall():
                taken.add(r[0])
        except Exception:
            pass
        finally:
            try:
                mcur.close(); mconn.close()
            except Exception:
                pass
    return taken


def get_current_term():
    # Query master to find the most recent year/semester in sections
    conn = get_db_conn(5432)
    try:
        cur = conn.cursor()
        cur.execute("SELECT year, semester FROM sections ORDER BY year DESC, semester DESC LIMIT 1")
        row = cur.fetchone()
        if row:
            return {'year': row[0], 'semester': row[1]}
    except Exception:
        pass
    finally:
        conn.close()
    # fallback to None
    return None

# Trang chủ (render giao diện HTML)
@app.route('/')
def home():
    return render_template('index.html')

# Endpoint đăng ký course
@app.route('/register', methods=['POST'])
def register():
    data = request.json  # {stno: 1, sec_no: 1}
    if not data or 'stno' not in data or 'sec_no' not in data:
        return jsonify({'error': 'Missing stno or sec_no'}), 400

    # find student and its u_id across shards
    student_display = data.get('student_display')
    student = find_student(stno=int(data['stno']), fullname=student_display)
    if not student:
        return jsonify({'error': 'Student not found'}), 404
    u_id = student.get('u_id')
    # decide shard
    if 1 <= u_id <= 10:
        target_port = 5433
    else:
        target_port = 5434

    conn = get_db_conn(target_port)
    cur = conn.cursor()
    try:
        # insert on the student's shard and get created_at timestamp
        cur.execute("INSERT INTO registrations (stno, sec_no) VALUES (%s, %s) RETURNING created_at", (data['stno'], data['sec_no']))
        row = cur.fetchone()
        conn.commit()

        shard_created = row[0] if row else None

        # Gọi hàm sync mới dựa trên mapping (sync_registrations_remapped) nếu có
        sync_called = False
        sync_error = None
        try:
            master_conn = get_db_conn(5432)
            master_cur = master_conn.cursor()
            master_cur.execute("SELECT sync_registrations_remapped();")
            master_conn.commit()
            sync_called = True
        except Exception as se:
            sync_called = False
            sync_error = str(se)
        finally:
            try:
                master_cur.close(); master_conn.close()
            except Exception:
                pass

        return jsonify({'status': 'success', 'shard_created_at': str(shard_created) if shard_created else None, 'sync_called': sync_called, 'sync_error': sync_error})
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        try:
            cur.close()
        except Exception:
            pass
        try:
            conn.close()
        except Exception:
            pass
        if 'master_conn' in locals():
            try:
                master_cur.close()
            except Exception:
                pass
            try:
                master_conn.close()
            except Exception:
                pass
            
# Endpoint trả về toàn bộ danh sách đăng ký trên DB gốc kèm theo độ trễ đồng bộ.
@app.route('/list', methods=['GET'])
def list_registrations():
    conn = get_db_conn(5432)  # Master DB
    cur = conn.cursor()
    # use a generated row number as reg_id because the registrations table may not have an "id" column
    cur.execute("""
        SELECT
            row_number() OVER () AS reg_id,
            stno,
            sec_no,
            created_at,
            synced_at,
            (synced_at - created_at) AS latency
        FROM registrations;
    """)
    rows = cur.fetchall()
    cur.close()
    conn.close()

    result = []
    for r in rows:
        result.append({
            'id': r[0],
            'stno': r[1],
            'sec_no': r[2],
            'created_at': str(r[3]),
            'synced_at': str(r[4]) if r[4] else None,
            'latency': str(r[5]) if r[5] else None
        })
    return jsonify(result)


# Endpoint: autocomplete/search students
@app.route('/students', methods=['GET'])
def students():
    q = request.args.get('q', '').strip()
    if not q:
        return jsonify([])
    results = find_student(q=q)
    return jsonify(results)


# Endpoint: available sections for a student in current term
@app.route('/sections/available/<int:stno>', methods=['GET'])
def available_sections(stno):
    # find student
    student = find_student(stno=stno)
    if not student:
        return jsonify({'error': 'Student not found'}), 404

    shard_hint = request.args.get('shard')  # optional shard hint to resolve mapping

    term = get_current_term()
    if not term:
        return jsonify({'error': 'Current term unknown'}), 500

    year = term['year']
    semester = term['semester']

    # gather taken sections from master and shards
    taken = _taken_sections_from_shards(stno, year, semester, shard_hint=shard_hint)

    # Query master for sections in the current term, exclude those the student already registered for
    conn = get_db_conn(5432)
    try:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT s.sec_no, s.c_no, c.c_name, s.capacity,
                   (SELECT COUNT(*) FROM registrations r2 WHERE r2.sec_no = s.sec_no) AS enrolled,
                   i.name as instructor
            FROM sections s
            LEFT JOIN courses c ON s.c_no = c.c_no
            LEFT JOIN instructors i ON s.ins_id = i.ins_id
            WHERE s.year = %s AND s.semester = %s
            ORDER BY s.sec_no
            """,
            (year, semester)
        )
        rows = cur.fetchall()
        out = []
        for r in rows:
            sec_no, c_no, c_name, capacity, enrolled, instructor = r
            if sec_no in taken:
                continue
            if enrolled is None:
                enrolled = 0
            if capacity is not None and enrolled >= capacity:
                continue
            out.append({'sec_no': sec_no, 'course_no': c_no, 'course_name': c_name, 'capacity': capacity, 'enrolled': enrolled, 'instructor': instructor})
        return jsonify(out)
    except Exception as e:
        return jsonify({'error': str(e)}), 500
    finally:
        conn.close()

 # Manual sync endpoint (POST /sync) to trigger mapping-based registration sync
@app.route('/sync', methods=['POST'])
def manual_sync():
    try:
        conn = get_db_conn(5432)
        cur = conn.cursor()
        cur.execute("SELECT sync_registrations_remapped();")
        conn.commit()
        return jsonify({'status': 'ok'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500
    finally:
        try:
            cur.close(); conn.close()
        except Exception:
            pass

if __name__ == '__main__':
    app.run(debug=True)
