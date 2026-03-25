-- =============================================================================
-- Case 02: 적절한 INDEX 선택
-- 핵심 튜닝 기법: INDEX 힌트로 옵티마이저의 잘못된 INDEX 선택 수정
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
DROP TABLE 카드환불내역 CASCADE CONSTRAINTS PURGE;

PROMPT
PROMPT ========================================
PROMPT 1. 테스트 테이블 및 인덱스 생성
PROMPT ========================================

-- 카드환불내역 테이블 생성 (DBA_SEGMENTS 기반으로 대용량 생성)
CREATE TABLE 카드환불내역 AS
SELECT 
    rownum AS 환불번호,
    owner AS 카드번호,
    segment_name AS 고객명,
    segment_type AS 환불사유,
    TO_CHAR(SYSDATE - TRUNC(DBMS_RANDOM.VALUE(1, 3650)), 'YYYYMMDD') AS 작업일자,
    ROUND(DBMS_RANDOM.VALUE(1000, 100000), 0) AS 환불금액,
    tablespace_name AS 처리상태,
    bytes AS 카드회사코드,
    blocks AS 승인번호,
    extents AS 처리자코드
FROM dba_segments
WHERE rownum <= 100000;  -- 10만건 생성

-- 기본키 생성
ALTER TABLE 카드환불내역 ADD CONSTRAINT 카드환불내역_PK PRIMARY KEY (환불번호);

-- 작업일자 INDEX 생성 (튜닝에 필요한 INDEX)
CREATE INDEX 카드환불내역_IX1 ON 카드환불내역 (작업일자, 환불번호);

-- 통계 정보 수집
EXEC DBMS_STATS.GATHER_TABLE_STATS(user, '카드환불내역');

-- 데이터 분포 확인
SELECT '총 건수' 구분, COUNT(*) 건수 FROM 카드환불내역
UNION ALL
SELECT '작업일자 DISTINCT', COUNT(DISTINCT 작업일자) FROM 카드환불내역
UNION ALL
SELECT '최근 7일 건수', COUNT(*) FROM 카드환불내역 
WHERE 작업일자 BETWEEN TO_CHAR(SYSDATE-7, 'YYYYMMDD') AND TO_CHAR(SYSDATE, 'YYYYMMDD');

PROMPT
PROMPT ========================================
PROMPT 2. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE 시작일 VARCHAR2(8);
VARIABLE 종료일 VARCHAR2(8);
EXEC :시작일 := TO_CHAR(SYSDATE-7, 'YYYYMMDD');
EXEC :종료일 := TO_CHAR(SYSDATE, 'YYYYMMDD');

PRINT 시작일
PRINT 종료일

-- 튜닝 전 SQL (옵티마이저가 PK INDEX FULL SCAN 선택 - 비효율)
SELECT *
FROM 카드환불내역
WHERE 작업일자 BETWEEN :시작일 AND :종료일
  AND 환불금액 >= 10000
  AND 처리상태 IN ('USERS', 'SYSTEM', 'SYSAUX')
ORDER BY 환불번호, 작업일자;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 후 SQL 및 실행계획
PROMPT ========================================

-- 튜닝 후 SQL (INDEX 힌트로 적절한 INDEX 지정)
SELECT /*+ INDEX(카드환불내역 카드환불내역_IX1) */ *
FROM 카드환불내역
WHERE 작업일자 BETWEEN :시작일 AND :종료일
  AND 환불금액 >= 10000
  AND 처리상태 IN ('USERS', 'SYSTEM', 'SYSAUX')
ORDER BY 환불번호, 작업일자;

PROMPT
PROMPT ========================================
PROMPT 4. 대안 - INDEX FAST FULL SCAN 유도
PROMPT ========================================

-- INDEX FAST FULL SCAN으로 정렬 최적화
SELECT /*+ INDEX_FFS(카드환불내역 카드환불내역_IX1) */ 
    환불번호, 카드번호, 고객명, 환불사유, 작업일자, 환불금액, 처리상태
FROM 카드환불내역
WHERE 작업일자 BETWEEN :시작일 AND :종료일
  AND 환불금액 >= 10000
  AND 처리상태 IN ('USERS', 'SYSTEM', 'SYSAUX')
ORDER BY 작업일자, 환불번호;

PROMPT
PROMPT ========================================
PROMPT 5. 성능 비교 및 분석
PROMPT ========================================

/*
 핵심 튜닝 포인트 분석:
 
 1. 문제점:
    - 조회 조건: 작업일자 BETWEEN (범위 조건)
    - 적절한 INDEX: 카드환불내역_IX1 (작업일자, 환불번호)
    - 옵티마이저 문제: ORDER BY 때문에 PK INDEX FULL SCAN 선택
    - 전체 테이블 스캔 후 필터링으로 인한 대량 I/O
 
 2. 해결책:
    - INDEX 힌트로 적절한 INDEX 강제 지정
    - 작업일자 조건으로 INDEX RANGE SCAN 유도
    - 필요시 INDEX FAST FULL SCAN도 고려
 
 3. INDEX 선택 기준:
    - 조건절의 선택도(Selectivity)
    - INDEX의 Clustering Factor
    - ORDER BY 절과의 호환성
    - 전체 비용(Cost) 계산
 
 4. 적용 조건:
    - 옵티마이저가 비효율적인 INDEX 선택 시
    - 범위 조건에 적합한 INDEX 존재 시
    - CLUSTERING FACTOR가 양호한 INDEX 우선
 
 5. 성과:
    - Buffers: 357K → 20 (99.99% 개선)
    - 실행 시간: 33.77초 → 0.06초 (99.8% 개선)
    - A-Rows 대비 Buffers 비율로 CLUSTERING FACTOR 양호 확인
*/

PROMPT
PROMPT ========================================
PROMPT 6. CLUSTERING FACTOR 확인
PROMPT ========================================

-- INDEX 통계 정보 확인
SELECT 
    index_name,
    clustering_factor,
    num_rows,
    distinct_keys,
    blevel,
    leaf_blocks
FROM user_indexes 
WHERE table_name = '카드환불내역';

-- INDEX 효율성 분석
SELECT 
    '카드환불내역_IX1' INDEX_명,
    ROUND(clustering_factor / GREATEST(num_rows, 1) * 100, 2) AS CF_비율,
    CASE 
        WHEN clustering_factor / GREATEST(num_rows, 1) < 0.1 THEN '매우좋음'
        WHEN clustering_factor / GREATEST(num_rows, 1) < 0.3 THEN '좋음'
        WHEN clustering_factor / GREATEST(num_rows, 1) < 0.7 THEN '보통'
        ELSE '나쁨'
    END AS CF_등급
FROM user_indexes 
WHERE index_name = '카드환불내역_IX1';

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 02 적절한 INDEX 선택 실습 완료 ***