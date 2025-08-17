CREATE DATABASE enrollment_db;
\c enrollment_db

CREATE TABLE universities (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    location VARCHAR(50),
    group_type VARCHAR(10)  -- Public/Private
);

CREATE TABLE colleges (
    col_id SERIAL PRIMARY KEY,
    col_name VARCHAR(100),
    u_id INTEGER REFERENCES universities(id)
);

CREATE TABLE departments (
    dep_id SERIAL PRIMARY KEY,
    dep_name VARCHAR(100),
    col_id INTEGER REFERENCES colleges(col_id)
);

CREATE TABLE courses (
    c_no VARCHAR(10) PRIMARY KEY,
    c_name VARCHAR(100),
    c_desc TEXT,
    c_hours INTEGER,
    preq VARCHAR(10)  -- Prerequisite course no
);

CREATE TABLE instructors (
    ins_id SERIAL PRIMARY KEY,
    u_id INTEGER REFERENCES universities(id),
    name VARCHAR(100),
    email VARCHAR(100),
    rank VARCHAR(50),
    office VARCHAR(50)
);

CREATE TABLE students (
    stno SERIAL PRIMARY KEY,
    u_id INTEGER REFERENCES universities(id),
    col_id INTEGER REFERENCES colleges(col_id),
    dep_id INTEGER REFERENCES departments(dep_id),
    fname VARCHAR(30),
    mname VARCHAR(30),
    lname VARCHAR(30),
    st_address VARCHAR(60),
    gender CHAR(1),
    prog_degree INTEGER,
    dob DATE
);

CREATE TABLE sections (
    sec_no SERIAL PRIMARY KEY,
    year INTEGER,
    semester VARCHAR(10),
    time VARCHAR(20),
    hall VARCHAR(20),
    c_no VARCHAR(10) REFERENCES courses(c_no),
    ins_id INTEGER REFERENCES instructors(ins_id),
    capacity INTEGER
);

CREATE TABLE registrations (
    reg_id SERIAL PRIMARY KEY,
    stno INTEGER REFERENCES students(stno),
    sec_no INTEGER REFERENCES sections(sec_no),
    created_at TIMESTAMP DEFAULT now(),
    synced_at TIMESTAMP,
    mark FLOAT
);

-- Insert full universities từ Table 1 PDF
INSERT INTO universities (id, name, location, group_type) VALUES
(1, 'The University of Jordan', 'Amman', 'Public'),
(2, 'Yarmouk University', 'Irbid', 'Public'),
(3, 'Jordan University of Science and Technology', 'Irbid', 'Public'),
(4, 'The Hashemite University', 'Zarqa', 'Public'),
(5, 'AL-Balqa Applied University', 'Balqa', 'Public'),
(6, 'Mutah University', 'Karak', 'Public'),
(7, 'Al al-Bayt University', 'Mafraq', 'Public'),
(8, 'AL-Hussein Bin Talal University', 'Ma’an', 'Public'),
(9, 'Tafila Technical University', 'Tafila', 'Public'),
(10, 'German Jordanian University', 'Amman', 'Public'),
(11, 'Zarqa University', 'Zarqa', 'Private'),
(12, 'Princess Sumaya University for Technology', 'Amman', 'Private'),
(13, 'Al - Ahliyya Amman University', 'Amman', 'Private'),
(14, 'Applied Science University', 'Amman', 'Private'),
(15, 'Philadelphia University', 'Amman', 'Private'),
(16, 'Petra University', 'Amman', 'Private'),
(17, 'Al-Zaytoonah University of Jordan', 'Amman', 'Private'),
(18, 'Isra University', 'Amman', 'Private'),
(19, 'Middle East University', 'Amman', 'Private'),
(20, 'Amman Arab University', 'Amman', 'Private'),
(21, 'American University of Madaba', 'Madaba', 'Private'),
(22, 'Jerash University', 'Jerash', 'Private'),
(23, 'Jadara University', 'Irbid', 'Private'),
(24, 'Irbid National University', 'Irbid', 'Private'),
(25, 'Aqaba university of technology', 'Aqaba', 'Private'),
(26, 'Ajloun National University', 'Ajloun', 'Private');

-- Insert colleges từ Table 2 PDF (u_id giả định 1 cho sample)
INSERT INTO colleges (col_id, col_name, u_id) VALUES
(1, 'Faculty of Medicine', 1),
(2, 'Faculty of Engineering', 1),
(3, 'Faculty of Science', 1),
(4, 'Faculty of Pharmacy', 1),
(5, 'Faculty of Admister and Business', 1),
(6, 'Faculty of Information Technology', 1),
(7, 'Faculty of Dentistry', 1),
(8, 'Faculty of Nursing', 1),
(9, 'Faculty of Arts', 1);

-- Insert departments từ Table 3 PDF
INSERT INTO departments (dep_id, dep_name, col_id) VALUES
(1, 'Department of Anatomy and Histology', 1),
(2, 'Department of Pharmaceutical Sciences', 4),
(3, 'Department of Civil Engineering', 2),
(4, 'Department of Computer Science', 6),
(5, 'Department of Computer Information Systems', 6),
(6, 'Department of Software Engineering', 6);

-- Insert courses mẫu (mở rộng)
INSERT INTO courses (c_no, c_name, c_desc, c_hours, preq) VALUES
('CS101', 'Introduction to Computer Science', 'Basic CS concepts', 3, NULL),
('ENG201', 'Engineering Math', 'Math for engineers', 3, 'CS101'),
('MED301', 'Anatomy Basics', 'Human anatomy intro', 4, NULL),
('PHAR401', 'Pharmaceutical Chemistry', 'Drug chemistry', 3, 'MED301');

-- Insert instructors mẫu (phân theo u_id public và private)
INSERT INTO instructors (u_id, name, email, rank, office) VALUES
(1, 'Instructor A Public', 'a@public.edu', 'Professor', 'Office 101'),  -- Public
(2, 'Instructor B Public', 'b@public.edu', 'Lecturer', 'Office 102'),  -- Public
(3, 'Instructor C Public', 'c@public.edu', 'Assistant', 'Office 103'),  -- Public
(11, 'Instructor D Private', 'd@private.edu', 'Professor', 'Office 201'),  -- Private
(12, 'Instructor E Private', 'e@private.edu', 'Lecturer', 'Office 202'),  -- Private
(13, 'Instructor F Private', 'f@private.edu', 'Assistant', 'Office 203');  -- Private

-- Insert students mẫu (phân theo u_id)
INSERT INTO students (u_id, col_id, dep_id, fname, mname, lname, st_address, gender, prog_degree, dob) VALUES
(1, 1, 1, 'Student1', 'Pub', 'One', 'Amman Addr1', 'M', 1, '2000-01-01'),  -- Public
(2, 2, 3, 'Student2', 'Pub', 'Two', 'Irbid Addr2', 'F', 2, '2001-02-02'),  -- Public
(3, 3, 4, 'Student3', 'Pub', 'Three', 'Zarqa Addr3', 'M', 1, '2002-03-03'),  -- Public
(11, 6, 4, 'Student4', 'Priv', 'Four', 'Zarqa Addr4', 'F', 2, '2003-04-04'),  -- Private
(12, 7, 5, 'Student5', 'Priv', 'Five', 'Amman Addr5', 'M', 1, '2004-05-05'),  -- Private
(13, 1, 1, 'Student6', 'Priv', 'Six', 'Amman Addr6', 'F', 2, '2005-06-06');  -- Private

-- Insert sections mẫu (liên kết ins_id theo u_id)
INSERT INTO sections (year, semester, time, hall, c_no, ins_id, capacity) VALUES
(2024, 'Fall', '10:00-11:00', 'Hall1', 'CS101', 1, 30),  -- Public ins
(2024, 'Fall', '11:00-12:00', 'Hall2', 'ENG201', 2, 25),  -- Public
(2024, 'Fall', '12:00-13:00', 'Hall3', 'MED301', 3, 20),  -- Public
(2024, 'Fall', '13:00-14:00', 'Hall4', 'PHAR401', 4, 35),  -- Private
(2024, 'Fall', '14:00-15:00', 'Hall5', 'CS101', 5, 30),  -- Private
(2024, 'Fall', '15:00-16:00', 'Hall6', 'ENG201', 6, 25);  -- Private