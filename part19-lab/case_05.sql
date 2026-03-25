-- =============================================================================
-- Case 05: JOIN → 스칼라 서브쿼리 변환
-- 핵심 튜닝 기법: UNIQUE KEY JOIN을 스칼라 서브쿼리로 변환하여 캐싱 효과 활용
-- 관련 단원: 서브쿼리 최적화
-- 공통 데이터 세트: T_ORDER + T_CODE 테이블 사용
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 공통 데이터 세트 확인
SELECT '데이터 확인' AS 구분,
       (SELECT COUNT(*) FROM T_ORDER) AS ORDER_건수,
       (SELECT COUNT(*) FROM T_CODE) AS CODE_건수
FROM DUAL;

PROMPT
PROMPT ========================================
PROMPT 1. 스칼라 서브쿼리 시나리오 설명
PROMPT ========================================

/*
스칼라 서브쿼리 최적화 개념:
- 1:1 또는 M:1 JOIN을 스칼라 서브쿼리로 변환
- Oracle의 스칼라 서브쿼리 캐싱 기능 활용
- 동일한 입력값에 대해 결과를 메모리에 캐시하여 재사용

시나리오: 주문 상태별 상태명 조회
- T_ORDER (100만건) + T_CODE (200건)
- status 컬럼으로 조인하여 상태명 가져오기
- 중복된 status 값이 많아 캐싱 효과 극대화 가능

적용 조건:
- 참조 테이블(T_CODE)이 작고 변화가 적음
- JOIN 키(status)의 DISTINCT 값이 적음
- 1:1 매핑 보장 (UNIQUE KEY)
*/

PROMPT
PROMPT ========================================
PROMPT 2. 데이터 분포 및 캐싱 효과 분석
PROMPT ========================================

-- 주문 상태별 분포 확인 (캐싱 효율성 판단)
SELECT status, COUNT(*) AS 건수,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM T_ORDER), 2) AS 비율_PCT
FROM T_ORDER
GROUP BY status
ORDER BY COUNT(*) DESC;

-- 코드 테이블 확인
SELECT code_group, code, code_name
FROM T_CODE
WHERE code_group = 'ORDER_STATUS'
ORDER BY code;

-- 스칼라 서브쿼리 캐싱 효과 예상치 계산
WITH cache_analysis AS (
    SELECT 
        COUNT(*) AS total_rows,
        COUNT(DISTINCT status) AS distinct_status,
        ROUND(COUNT(*) / COUNT(DISTINCT status), 2) AS avg_rows_per_status
    FROM T_ORDER
)
SELECT 
    total_rows AS 전체_주문건수,
    distinct_status AS 상태_종류수,
    avg_rows_per_status AS 상태당_평균건수,
    CASE WHEN distinct_status <= 10 THEN '캐싱_효과_높음'
         WHEN distinct_status <= 50 THEN '캐싱_효과_보통'
         ELSE '캐싱_효과_낮음' END AS 캐싱_효과_예상
FROM cache_analysis;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획 (JOIN)
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_START_DATE DATE;
VARIABLE B_END_DATE DATE;
EXEC :B_START_DATE := DATE '2024-06-01';
EXEC :B_END_DATE := DATE '2024-06-30';

-- 튜닝 전 SQL (일반적인 JOIN 사용)
-- T_CODE 테이블을 매번 ACCESS하여 상태명 조회
SELECT 
    o.order_id,
    o.cust_id,
    o.order_date,
    o.status,
    c.code_name AS 상태명,
    o.total_amount,
    o.store_id,
    o.region_code
FROM T_ORDER o,
     T_CODE c
WHERE o.status = c.code
  AND c.code_group = 'ORDER_STATUS'
  AND o.order_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND o.total_amount > 50000
ORDER BY o.order_date DESC, o.order_id;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획 (스칼라 서브쿼리)
PROMPT ========================================

-- 튜닝 후 SQL (스칼라 서브쿼리 사용)
-- 동일한 status 값에 대해 캐싱된 결과 재사용
SELECT 
    o.order_id,
    o.cust_id,
    o.order_date,
    o.status,
    (SELECT c.code_name 
     FROM T_CODE c 
     WHERE c.code = o.status 
       AND c.code_group = 'ORDER_STATUS') AS 상태명,
    o.total_amount,
    o.store_id,
    o.region_code
FROM T_ORDER o
WHERE o.order_date BETWEEN :B_START_DATE AND :B_END_DATE
  AND o.total_amount > 50000
ORDER BY o.order_date DESC, o.order_id;

PROMPT
PROMPT ========================================
PROMPT 5. 스칼라 서브쿼리 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. 스칼라 서브쿼리 캐싱 메커니즘:
   - Oracle 내부적으로 Hash Table 유지
   - 동일 입력값 → 캐시된 결과 즉시 반환
   - 캐시 크기 제한: _scalar_subquery_cache_size (기본 256개)
   - LRU 방식으로 캐시 관리

2. 성능 향상 원리:
   - JOIN 제거 → 테이블 ACCESS 횟수 감소
   - 캐시 HIT 시 논리적 I/O 0건
   - CPU 연산량 절약 (Hash Lookup만)

3. 적용 조건:
   ✅ 참조 테이블이 작음 (< 1000건)
   ✅ JOIN 키의 DISTINCT 값이 적음 (< 200개)
   ✅ 1:1 또는 M:1 관계 보장
   ✅ 참조 테이블 변경 빈도 낮음

4. 주의사항:
   ❌ DISTINCT 값이 많으면 캐시 미스 빈발
   ❌ 서브쿼리 결과가 여러 건이면 오류
   ❌ 참조 테이블이 자주 변하면 일관성 문제

5. 성과:
   - 논리적 I/O 대폭 감소 (캐시 HIT 시)
   - JOIN Operation 제거
   - 실행계획 단순화
*/

-- 스칼라 서브쿼리 vs JOIN 성능 비교
PROMPT
PROMPT === 성능 비교: 집계 쿼리 ===

-- 1) JOIN 방식
SELECT 
    o.status,
    c.code_name AS 상태명,
    COUNT(*) AS 건수,
    SUM(o.total_amount) AS 총액
FROM T_ORDER o,
     T_CODE c
WHERE o.status = c.code
  AND c.code_group = 'ORDER_STATUS'
  AND o.order_date >= DATE '2024-01-01'
GROUP BY o.status, c.code_name
ORDER BY COUNT(*) DESC;

-- 2) 스칼라 서브쿼리 방식
SELECT 
    status,
    (SELECT code_name FROM T_CODE 
     WHERE code = o.status AND code_group = 'ORDER_STATUS') AS 상태명,
    COUNT(*) AS 건수,
    SUM(total_amount) AS 총액
FROM T_ORDER o
WHERE o.order_date >= DATE '2024-01-01'
GROUP BY status
ORDER BY COUNT(*) DESC;

PROMPT
PROMPT ========================================
PROMPT 6. 캐싱 효과 실증 테스트
PROMPT ========================================

-- 캐싱 효과 확인을 위한 반복 조회
PROMPT === 반복 조회 성능 테스트 ===

-- 동일한 쿼리를 여러 번 실행하여 캐싱 효과 확인
SELECT COUNT(*), AVG(total_amount)
FROM T_ORDER o
WHERE (SELECT code_name FROM T_CODE 
       WHERE code = o.status AND code_group = 'ORDER_STATUS') = '주문완료'
  AND order_date >= DATE '2024-01-01';

-- 다양한 상태값에 대한 조회 (캐시 활용)
SELECT 
    status,
    (SELECT code_name FROM T_CODE 
     WHERE code = o.status AND code_group = 'ORDER_STATUS') AS 상태명,
    COUNT(*)
FROM T_ORDER o 
WHERE order_date >= DATE '2024-06-01'
  AND status IN ('ACTIVE', 'COMPLETE', 'CANCEL')
GROUP BY status;

PROMPT
PROMPT ========================================
PROMPT 7. 실무 적용 가이드
PROMPT ========================================

/*
스칼라 서브쿼리 실무 활용 가이드:

✅ 적용 권장 시나리오:
- 코드성 테이블 조인 (공통코드, 분류코드 등)
- 참조 테이블 크기 < 1MB
- JOIN 키 DISTINCT 값 < 1000개
- 조회 빈도 높은 경우

❌ 적용 비권장 시나리오:
- 대용량 참조 테이블
- JOIN 키 DISTINCT 값 > 10000개
- 1:M 관계 (결과 여러 건)
- 참조 테이블 실시간 변경

🔧 최적화 체크리스트:
1. 참조 테이블 크기 확인
2. JOIN 키 DISTINCT 값 개수 확인
3. 1:1 관계 보장 확인 (UNIQUE 제약조건)
4. 실행계획에서 TABLE ACCESS 횟수 비교
5. 논리적 I/O 감소량 측정

📊 성능 모니터링:
- v$sesstat: consistent gets, physical reads
- v$sql: executions, buffer_gets
- 캐시 효율성 = (전체 호출 - 실제 ACCESS) / 전체 호출

💡 추가 최적화 기법:
- DETERMINISTIC 함수로 캐싱 강화
- RESULT_CACHE 힌트 활용
- PL/SQL 함수 기반 캐싱 구현
*/

-- 캐싱 효율성 정량 측정
PROMPT
PROMPT === 캐싱 효율성 정량 측정 ===

WITH caching_stats AS (
    SELECT 
        status,
        COUNT(*) AS total_calls,
        1 AS actual_lookups  -- 각 status당 1번만 실제 조회
    FROM T_ORDER 
    WHERE order_date >= DATE '2024-01-01'
      AND status IN ('ACTIVE', 'COMPLETE', 'CANCEL', 'PENDING')
    GROUP BY status
)
SELECT 
    status,
    total_calls AS 총호출횟수,
    actual_lookups AS 실제조회횟수,
    total_calls - actual_lookups AS 캐시활용횟수,
    ROUND((total_calls - actual_lookups) * 100.0 / total_calls, 2) AS 캐시효율성_PCT
FROM caching_stats
ORDER BY total_calls DESC;

-- 결과 동일성 검증
PROMPT
PROMPT === 결과 동일성 검증 ===

WITH join_result AS (
    SELECT COUNT(*) AS cnt, SUM(o.total_amount) AS sum_amt
    FROM T_ORDER o, T_CODE c
    WHERE o.status = c.code AND c.code_group = 'ORDER_STATUS'
      AND o.order_date BETWEEN :B_START_DATE AND :B_END_DATE
      AND o.total_amount > 50000
), scalar_result AS (
    SELECT COUNT(*) AS cnt, SUM(total_amount) AS sum_amt
    FROM T_ORDER o
    WHERE (SELECT 1 FROM T_CODE WHERE code = o.status AND code_group = 'ORDER_STATUS') = 1
      AND o.order_date BETWEEN :B_START_DATE AND :B_END_DATE  
      AND o.total_amount > 50000
)
SELECT 
    jr.cnt AS JOIN_건수, sr.cnt AS 스칼라_건수,
    jr.sum_amt AS JOIN_금액합계, sr.sum_amt AS 스칼라_금액합계,
    CASE WHEN jr.cnt = sr.cnt AND jr.sum_amt = sr.sum_amt 
         THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM join_result jr, scalar_result sr;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 05 JOIN → 스칼라 서브쿼리 변환 실습 완료 ***
PROMPT *** 다음: case_06.sql (EXISTS + JOIN 순서 변경) ***