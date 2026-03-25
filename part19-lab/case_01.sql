-- =============================================================================
-- Case 01: INDEX SKIP SCAN 활용
-- 핵심 튜닝 기법: INDEX SKIP SCAN으로 중간 컬럼 누락 문제 해결
-- 관련 단원: INDEX ACCESS 패턴
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 정리 (재실행 시)
DROP TABLE 외화수표일별 CASCADE CONSTRAINTS PURGE;
DROP TABLE 외화수표매입 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- 외화수표일별 테이블 생성 (DBA_OBJECTS 기반)
CREATE TABLE 외화수표일별 AS
SELECT 
    SUBSTR(owner, 1, 1) AS 중앙회조합구분코드,
    MOD(object_id, 3) AS 매입추심구분코드,  -- 0,1,2 (3가지 값)
    TO_CHAR(created, 'YYYYMMDD') AS 거래일자,
    SUBSTR(object_name, 1, 4) AS 사무소코드,
    object_id AS 외화수표거래번호,
    owner AS 대표고객번호,
    object_name AS 고객번호,
    object_type AS 계리세목코드,
    'USD' AS 통화코드,
    ROUND(DBMS_RANDOM.VALUE(100, 10000), 2) AS 외화잔액,
    created,
    last_ddl_time
FROM dba_objects
WHERE rownum <= 50000;  -- 5만건 생성

-- 외화수표매입 테이블 생성
CREATE TABLE 외화수표매입 AS
SELECT DISTINCT
    외화수표거래번호,
    TO_DATE('2024-01-01', 'YYYY-MM-DD') + TRUNC(DBMS_RANDOM.VALUE(1, 365)) AS 신규일자,
    TO_DATE('2024-01-01', 'YYYY-MM-DD') + TRUNC(DBMS_RANDOM.VALUE(1, 365)) AS 입금예정일자,
    TRUNC(DBMS_RANDOM.VALUE(1, 100)) AS 환율변동회차,
    'A' || MOD(rownum, 10) AS 외환상태코드
FROM 외화수표일별
WHERE rownum <= 10000;

-- PK 생성
ALTER TABLE 외화수표매입 ADD CONSTRAINT PK_외화수표매입 PRIMARY KEY (외화수표거래번호);

-- 핵심 INDEX 생성: [중앙회조합구분코드, 매입추심구분코드, 거래일자, 사무소코드]
CREATE INDEX IX_외화수표일별_N1 ON 외화수표일별 (
    중앙회조합구분코드, 매입추심구분코드, 거래일자, 사무소코드
);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '외화수표일별');
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '외화수표매입');

-- INDEX 컬럼별 DISTINCT 값 확인
SELECT '중앙회조합구분코드' 컬럼명, COUNT(DISTINCT 중앙회조합구분코드) DISTINCT_CNT FROM 외화수표일별
UNION ALL
SELECT '매입추심구분코드' 컬럼명, COUNT(DISTINCT 매입추심구분코드) FROM 외화수표일별
UNION ALL  
SELECT '거래일자' 컬럼명, COUNT(DISTINCT 거래일자) FROM 외화수표일별;

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B0 VARCHAR2(10);
EXEC :B0 := '20240301';

-- 튜닝 전 SQL (INDEX RANGE SCAN 사용 - 비효율)
SELECT 
    T3.사무소코드, T3.외화수표거래번호, T3.대표고객번호,
    T3.고객번호, T3.계리세목코드, T2.신규일자,
    T2.입금예정일자, T3.통화코드,
    T3.외화잔액, T2.환율변동회차, T2.외환상태코드
FROM 외화수표매입 T2,
     (SELECT 
          T1.사무소코드, T1.외화수표거래번호, T1.대표고객번호,
          T1.고객번호, T1.계리세목코드, T1.통화코드,
          SUM(T1.외화잔액) 외화잔액
      FROM 외화수표일별 T1
      WHERE T1.중앙회조합구분코드 = '1'
        AND T1.거래일자 LIKE (:B0 || '%')
      GROUP BY T1.사무소코드, T1.외화수표거래번호, T1.대표고객번호,
               T1.고객번호, T1.계리세목코드, T1.통화코드) T3
WHERE T2.외화수표거래번호 = T3.외화수표거래번호;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (INDEX SKIP SCAN 사용)
SELECT 
    T3.사무소코드, T3.외화수표거래번호, T3.대표고객번호,
    T3.고객번호, T3.계리세목코드, T2.신규일자,
    T2.입금예정일자, T3.통화코드,
    T3.외화잔액, T2.환율변동회차, T2.외환상태코드
FROM 외화수표매입 T2,
     (SELECT /*+ INDEX_SS(T1 IX_외화수표일별_N1) */
          T1.사무소코드, T1.외화수표거래번호, T1.대표고객번호,
          T1.고객번호, T1.계리세목코드, T1.통화코드,
          SUM(T1.외화잔액) 외화잔액
      FROM 외화수표일별 T1
      WHERE T1.중앙회조합구분코드 = '1'
        AND T1.거래일자 LIKE (:B0 || '%')
      GROUP BY T1.사무소코드, T1.외화수표거래번호, T1.대표고객번호,
               T1.고객번호, T1.계리세목코드, T1.통화코드) T3
WHERE T2.외화수표거래번호 = T3.외화수표거래번호;

PROMPT
PROMPT ========================================
PROMPT 4. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - INDEX 컬럼: [중앙회조합구분코드, 매입추심구분코드, 거래일자, 사무소코드]
    - 조건: 중앙회조합구분코드='1' AND 거래일자 LIKE
    - 중간 컬럼인 매입추심구분코드가 누락 → 중앙회조합구분코드 이후는 필터 조건
    - 넓은 범위 INDEX SCAN 발생
 
 2. 해결책:
    - INDEX SKIP SCAN 활용 (매입추심구분코드의 DISTINCT 값이 3개로 적음)
    - INDEX_SS 힌트로 거래일자 LIKE 조건을 ACCESS 조건처럼 사용
    - INDEX SCAN 범위 대폭 축소
 
 3. 적용 조건:
    - 누락된 중간 컬럼의 DISTINCT 값이 적어야 함 (일반적으로 10개 이하)
    - 뒤쪽 컬럼에 유용한 조건이 있어야 함
    - CBO가 자동으로 선택하지 않을 때 INDEX_SS 힌트 사용
 
 4. 성과:
    - INDEX Block 읽기: 대폭 감소 (101K → 33)
    - 실행 시간: 99.5% 개선 (2분 17초 → 0.62초)
    - A-Rows는 동일하지만 Buffers가 크게 줄어듬
*/

PROMPT
PROMPT ========================================
PROMPT 5. 추가 검증
PROMPT ========================================

-- 매입추심구분코드별 분포 확인
SELECT 매입추심구분코드, COUNT(*) 건수
FROM 외화수표일별
WHERE 중앙회조합구분코드 = '1'
GROUP BY 매입추심구분코드
ORDER BY 매입추심구분코드;

-- 거래일자별 분포 확인  
SELECT SUBSTR(거래일자, 1, 6) 년월, COUNT(*) 건수
FROM 외화수표일별
WHERE 중앙회조합구분코드 = '1'
GROUP BY SUBSTR(거래일자, 1, 6)
ORDER BY 1;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 01 INDEX SKIP SCAN 실습 완료 ***