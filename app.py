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

# Trang chủ (render giao diện HTML)
@app.route('/')
def home():
    return render_template('index.html')

# Endpoint đăng ký course
@app.route('/register', methods=['POST'])
def register():
    data = request.json  # {stno: 1, sec_no: 1, u_id: 1}
    u_id = data.get('u_id')
    if u_id is None:
        return jsonify({'error': 'Missing u_id'}), 400
    
    if 1 <= u_id <= 10:  # Public -> 5433
        conn = get_db_conn(5433)
    elif 11 <= u_id <= 26:  # Private -> 5434
        conn = get_db_conn(5434)
    else:
        return jsonify({'error': 'Invalid u_id'}), 400
    
    cur = conn.cursor()
    try:
        cur.execute("INSERT INTO registrations (stno, sec_no) VALUES (%s, %s)", (data['stno'], data['sec_no']))
        conn.commit()
        
        # Sync to master (gọi function sync, giả sử có function sync_registrations tương tự sync_students)
        master_conn = get_db_conn(5432)
        master_cur = master_conn.cursor()
        master_cur.execute("SELECT sync_registrations();")  # Giả sử bạn đã định nghĩa function này ở master DB
        master_conn.commit()
        
        return jsonify({'status': 'success'})
    except Exception as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close()
        conn.close()
        if 'master_conn' in locals():
            master_cur.close()
            master_conn.close()
            
# Endpoint trả về toàn bộ danh sách đăng ký trên DB gốc kèm theo độ trễ đồng bộ.
@app.route('/list', methods=['GET'])
def list_registrations():
    conn = get_db_conn(5432)  # Master DB
    cur = conn.cursor()
    cur.execute("SELECT id, stno, sec_no, created_at, synced_at, (synced_at - created_at) AS latency FROM registrations;")
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

if __name__ == '__main__':
    app.run(debug=True)
