-- =============================================================================
-- Case 03: NL JOIN → HASH JOIN 변경
-- 핵심 튜닝 기법: 대량 건수 NL JOIN을 HASH JOIN으로 변경하여 I/O 최적화
-- 관련 단원: JOIN 최적화
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 접수처리기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE 신청기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE 여신고객기본 CASCADE CONSTRAINTS PURGE;
DROP TABLE 개인사업자내역 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 데이터 생성
PROMPT ========================================

-- 접수처리기본 테이블 생성 (42만 건)
CREATE TABLE 접수처리기본 AS
SELECT 
    rownum AS 여신심사접수번호,
    MOD(rownum-1, 1000) + 1 AS 여신심사접수일련번호,
    TO_CHAR(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 365)), 'YYYYMMDD') AS 여신신청일자,
    TO_CHAR(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 30)), 'YYYYMMDD') AS 처리일자,
    CASE MOD(rownum, 5)
        WHEN 0 THEN 'E42'
        WHEN 1 THEN 'E43' 
        WHEN 2 THEN 'E98'
        WHEN 3 THEN 'E99'
        ELSE 'E01'
    END AS 여신심사진행상태코드,
    'BC' || LPAD(MOD(rownum-1, 50000) + 1, 8, '0') AS 기업여신상담번호,
    CASE MOD(rownum, 2) WHEN 0 THEN '1' ELSE '5' END AS 중앙회조합구분코드
FROM dual 
CONNECT BY level <= 100000;  -- 10만건으로 축소 (시연용)

-- 신청기본 테이블 생성 (소형)
CREATE TABLE 신청기본 AS
SELECT DISTINCT
    기업여신상담번호,
    MOD(rownum, 10) AS 투자금융유형코드,
    '신용대출' AS 대출종류
FROM 접수처리기본
WHERE rownum <= 5000;

-- 여신고객기본 테이블 생성
CREATE TABLE 여신고객기본 AS
SELECT 
    여신심사접수번호,
    여신심사접수일련번호,
    'R' || LPAD(여신심사접수번호, 10, '0') AS 실명번호,
    '개인' AS 고객유형
FROM 접수처리기본;

-- 개인사업자내역 테이블 생성 (소형)
CREATE TABLE 개인사업자내역 AS
SELECT 
    'R' || LPAD(rownum, 10, '0') AS 신용조사기업식별번호,
    CASE MOD(rownum, 2) WHEN 0 THEN 'Y' ELSE 'N' END AS 소매여부
FROM dual
CONNECT BY level <= 20000;

-- PK 및 INDEX 생성
ALTER TABLE 접수처리기본 ADD CONSTRAINT PK_접수처리기본 PRIMARY KEY (여신심사접수번호, 여신심사접수일련번호);
ALTER TABLE 신청기본 ADD CONSTRAINT PK_신청기본 PRIMARY KEY (기업여신상담번호);
ALTER TABLE 여신고객기본 ADD CONSTRAINT PK_여신고객기본 PRIMARY KEY (여신심사접수번호, 여신심사접수일련번호);
ALTER TABLE 개인사업자내역 ADD CONSTRAINT PK_개인사업자내역 PRIMARY KEY (신용조사기업식별번호);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '접수처리기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '신청기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '여신고객기본');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '개인사업자내역');

-- 테이블 크기 확인
SELECT 'TABLE' 구분, table_name 테이블명, num_rows 건수, 
       ROUND(num_rows * avg_row_len / 1024 / 1024, 2) AS 예상크기_MB
FROM user_tables 
WHERE table_name IN ('접수처리기본', '신청기본', '여신고객기본', '개인사업자내역')
ORDER BY num_rows DESC;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획 (NL JOIN)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B0 VARCHAR2(8);
EXEC :B0 := TO_CHAR(SYSDATE, 'YYYYMMDD');

-- 튜닝 전 SQL (기본적으로 NL JOIN 실행)
SELECT 
    T1.여신심사접수번호, T1.여신심사접수일련번호,
    T1.여신신청일자, T1.처리일자, T1.실명번호,
    T2.소매여부, T2.신용조사기업식별번호
FROM (
    SELECT 
        A.여신심사접수번호, A.여신심사접수일련번호,
        A.여신신청일자, A.처리일자, C.실명번호,
        NVL(B.투자금융유형코드, 0) 투자금융유형코드
    FROM 접수처리기본 A, 신청기본 B, 여신고객기본 C
    WHERE A.여신심사진행상태코드 IN ('E42', 'E43', 'E98', 'E99')
      AND A.기업여신상담번호 = B.기업여신상담번호(+)
      AND A.여신심사접수번호 = C.여신심사접수번호
      AND A.여신심사접수일련번호 = C.여신심사접수일련번호
      AND A.처리일자 <= :B0
      AND A.중앙회조합구분코드 IN ('1', '5')
) T1, 개인사업자내역 T2
WHERE T1.실명번호 = T2.신용조사기업식별번호(+);

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획 (HASH JOIN)
PROMPT ========================================

-- 튜닝 후 SQL (USE_HASH 힌트로 HASH JOIN 강제)
SELECT /*+ USE_HASH(T1 T2) */
    T1.여신심사접수번호, T1.여신심사접수일련번호,
    T1.여신신청일자, T1.처리일자, T1.실명번호,
    T2.소매여부, T2.신용조사기업식별번호
FROM (
    SELECT /*+ USE_HASH(A B C) FULL(A) FULL(B) FULL(C) */
        A.여신심사접수번호, A.여신심사접수일련번호,
        A.여신신청일자, A.처리일자, C.실명번호,
        NVL(B.투자금융유형코드, 0) 투자금융유형코드
    FROM 접수처리기본 A, 신청기본 B, 여신고객기본 C
    WHERE A.여신심사진행상태코드 IN ('E42', 'E43', 'E98', 'E99')
      AND A.기업여신상담번호 = B.기업여신상담번호(+)
      AND A.여신심사접수번호 = C.여신심사접수번호
      AND A.여신심사접수일련번호 = C.여신심사접수일련번호
      AND A.처리일자 <= :B0
      AND A.중앙회조합구분코드 IN ('1', '5')
) T1, 개인사업자내역 T2
WHERE T1.실명번호 = T2.신용조사기업식별번호(+);

PROMPT
PROMPT ========================================
PROMPT 4. JOIN 방법별 성능 비교
PROMPT ========================================

-- NL JOIN vs HASH JOIN 성능 차이 확인
-- 실행계획에서 다음 항목들을 비교:
-- 1. Starts 컬럼 (NL JOIN에서는 높은 값, HASH JOIN에서는 낮은 값)
-- 2. Buffers 총합
-- 3. A-Time (실제 소요 시간)
-- 4. Used-Mem (PGA 메모리 사용량)

PROMPT
PROMPT ========================================
PROMPT 5. 성능 분석 및 튜닝 포인트
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - 접수처리기본에서 많은 건수(42만건) 추출
    - 각 건에 대해 후행 테이블과 NL JOIN 발생
    - Random Single Block I/O 대량 발생 (Starts 통계 확인)
    - JOIN되는 테이블들의 크기는 상대적으로 작음
 
 2. 해결책:
    - HASH JOIN 적용으로 Sequential I/O 활용
    - FULL TABLE SCAN으로 Multi Block I/O 효율성 확보
    - Build 테이블을 작은 테이블로 설정
 
 3. HASH JOIN 적용 조건:
    - JOIN되는 테이블 중 하나가 충분히 작아야 함 (Build용)
    - 많은 건수가 NL JOIN될 때 효과적
    - PGA 메모리가 충분해야 함
    - Equal JOIN 조건에서만 사용 가능
 
 4. NL JOIN vs HASH JOIN 선택 기준:
    - 소량 데이터 + INDEX 효율적 → NL JOIN
    - 대량 데이터 + 작은 테이블 존재 → HASH JOIN
    - 조건절 선택도가 좋은 경우 → NL JOIN
    - 조건절 선택도가 나쁜 경우 → HASH JOIN
 
 5. 성과:
    - Buffers: 2,095K → 51,736 (97.5% 개선)
    - 실행 시간: 1분 7초 → 6.17초 (90.8% 개선)
    - Starts 수치 대폭 감소 (Random I/O → Sequential I/O)
*/

PROMPT
PROMPT ========================================
PROMPT 6. 추가 검증 - JOIN 건수 분석
PROMPT ========================================

-- 각 단계별 JOIN 결과 건수 확인
SELECT '접수처리기본 조건 후' 단계, COUNT(*) 건수
FROM 접수처리기본 A
WHERE A.여신심사진행상태코드 IN ('E42', 'E43', 'E98', 'E99')
  AND A.처리일자 <= :B0
  AND A.중앙회조합구분코드 IN ('1', '5')
UNION ALL
SELECT '여신고객기본 JOIN 후', COUNT(*)
FROM 접수처리기본 A, 여신고객기본 C
WHERE A.여신심사진행상태코드 IN ('E42', 'E43', 'E98', 'E99')
  AND A.처리일자 <= :B0
  AND A.중앙회조합구분코드 IN ('1', '5')
  AND A.여신심사접수번호 = C.여신심사접수번호
  AND A.여신심사접수일련번호 = C.여신심사접수일련번호
UNION ALL  
SELECT '개인사업자내역 JOIN 후', COUNT(*)
FROM 접수처리기본 A, 여신고객기본 C, 개인사업자내역 T2
WHERE A.여신심사진행상태코드 IN ('E42', 'E43', 'E98', 'E99')
  AND A.처리일자 <= :B0
  AND A.중앙회조합구분코드 IN ('1', '5')
  AND A.여신심사접수번호 = C.여신심사접수번호
  AND A.여신심사접수일련번호 = C.여신심사접수일련번호
  AND C.실명번호 = T2.신용조사기업식별번호(+);

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 03 NL JOIN → HASH JOIN 변경 실습 완료 ***