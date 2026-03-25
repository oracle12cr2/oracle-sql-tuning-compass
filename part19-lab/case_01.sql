-- =============================================================================
-- Case 01: INDEX SKIP SCAN 활용
-- 핵심 튜닝 기법: INDEX SKIP SCAN으로 중간 컬럼 누락 문제 해결
-- 관련 단원: INDEX ACCESS 패턴
-- 공통 데이터 세트: T_ORDER 테이블 사용
-- =============================================================================

-- 환경 설정
SET ECHO ON
SET FEEDBACK ON
SET TIMING ON
SET AUTOTRACE ON
SET LINESIZE 200
SET PAGESIZE 50

-- 공통 데이터 세트 확인
SELECT '데이터 확인' AS 구분, COUNT(*) AS T_ORDER_건수 FROM T_ORDER;

PROMPT
PROMPT ========================================
PROMPT 1. INDEX SKIP SCAN 시나리오 설명
PROMPT ========================================

/*
INDEX 구조: IDX_ORDER_01 (region_code, order_date, store_id)
시나리오: region_code 조건은 있지만, order_date (중간 컬럼)이 누락된 경우
문제점: 중간 컬럼 누락으로 INDEX 효율성 떨어짐
해결책: INDEX SKIP SCAN 활용

실제 상황 예시:
- 복합 INDEX: [지역코드, 주문일자, 매장코드]
- 조건: 지역코드='R01' AND 매장코드 IN (1,2,3,4,5)
- 중간 컬럼 주문일자 조건 없음 → INDEX SKIP SCAN 필요
*/

PROMPT
PROMPT ========================================
PROMPT 2. INDEX 및 데이터 분포 확인
PROMPT ========================================

-- INDEX 확인
SELECT index_name, column_name, column_position
FROM user_ind_columns  
WHERE index_name = 'IDX_ORDER_01'
ORDER BY column_position;

-- 컬럼별 DISTINCT 값 확인 (SKIP SCAN 가능 여부 판단)
SELECT 'region_code' AS 컬럼명, COUNT(DISTINCT region_code) AS DISTINCT_CNT FROM T_ORDER
UNION ALL
SELECT 'order_date', COUNT(DISTINCT order_date) FROM T_ORDER
UNION ALL  
SELECT 'store_id', COUNT(DISTINCT store_id) FROM T_ORDER;

-- region_code별 분포 확인
SELECT region_code, COUNT(*) AS 건수
FROM T_ORDER
WHERE region_code IN ('R01', 'R02', 'R03')
GROUP BY region_code
ORDER BY region_code;

PROMPT
PROMPT ========================================
PROMPT 3. 튜닝 전 SQL 및 실행계획
PROMPT ========================================

-- 바인드 변수 설정
VARIABLE B_REGION VARCHAR2(10);
EXEC :B_REGION := 'R01';

-- 튜닝 전 SQL (INDEX RANGE SCAN 사용 - 비효율)
-- 중간 컬럼(order_date) 누락으로 넓은 범위 SCAN 발생
SELECT 
    o.order_id,
    o.cust_id,
    o.region_code,
    o.order_date,
    o.store_id,
    o.status,
    o.total_amount
FROM T_ORDER o
WHERE o.region_code = :B_REGION
  AND o.store_id IN (1, 2, 3, 4, 5)
  AND o.total_amount > 100000
ORDER BY o.order_date DESC;

PROMPT
PROMPT ========================================
PROMPT 4. 튜닝 후 SQL 및 실행계획  
PROMPT ========================================

-- 튜닝 후 SQL (INDEX SKIP SCAN 사용)
-- INDEX_SS 힌트로 중간 컬럼을 건너뛰고 효율적인 ACCESS
SELECT /*+ INDEX_SS(o IDX_ORDER_01) */
    o.order_id,
    o.cust_id, 
    o.region_code,
    o.order_date,
    o.store_id,
    o.status,
    o.total_amount
FROM T_ORDER o
WHERE o.region_code = :B_REGION
  AND o.store_id IN (1, 2, 3, 4, 5)
  AND o.total_amount > 100000
ORDER BY o.order_date DESC;

PROMPT
PROMPT ========================================
PROMPT 5. INDEX SKIP SCAN 상세 분석
PROMPT ========================================

/*
핵심 튜닝 포인트 분석:

1. 문제 상황:
   - INDEX 구조: (region_code, order_date, store_id)
   - 조건: region_code='R01' AND store_id IN (1,2,3,4,5)
   - 중간 컬럼 order_date 조건 없음
   - 결과: region_code='R01' 이후 모든 데이터를 FILTER로 처리

2. INDEX SKIP SCAN 동작 원리:
   - order_date의 DISTINCT 값별로 논리적 분할
   - 각 분할에서 store_id 조건을 ACCESS 조건으로 사용
   - 중간 컬럼을 "건너뛰며" 효율적인 INDEX ACCESS

3. 적용 조건:
   - 누락된 중간 컬럼의 DISTINCT 값이 적어야 함 (일반적으로 20개 이하)
   - 후행 컬럼에 유용한 선택 조건이 있어야 함
   - INDEX 전체 크기 대비 결과 집합이 작아야 함

4. INDEX_SS 힌트 사용:
   - CBO가 자동 선택하지 않는 경우 명시적 지정
   - 통계 정보가 부정확한 경우 특히 유용
   - 실행계획에서 INDEX (SKIP SCAN) 확인

5. 성과:
   - INDEX Block 읽기 대폭 감소
   - 실행 시간 단축 (넓은 범위 SCAN → 선택적 ACCESS)
   - CPU 사용량 절약
*/

-- INDEX SKIP SCAN vs RANGE SCAN 비교를 위한 추가 테스트
PROMPT
PROMPT === 비교 테스트: 다양한 힌트별 실행계획 ===

-- 1) INDEX RANGE SCAN 강제 (넓은 범위)
SELECT /*+ INDEX_RS(o IDX_ORDER_01) */
    COUNT(*), AVG(total_amount)
FROM T_ORDER o
WHERE o.region_code = :B_REGION
  AND o.store_id IN (1, 2, 3, 4, 5);

-- 2) INDEX SKIP SCAN 강제 (효율적)  
SELECT /*+ INDEX_SS(o IDX_ORDER_01) */
    COUNT(*), AVG(total_amount)
FROM T_ORDER o  
WHERE o.region_code = :B_REGION
  AND o.store_id IN (1, 2, 3, 4, 5);

PROMPT
PROMPT ========================================
PROMPT 6. 실무 적용 가이드
PROMPT ========================================

/*
INDEX SKIP SCAN 실무 적용 시나리오:

✅ 적용 권장:
- 복합 INDEX에서 선두/중간 컬럼 조건 없음
- 누락 컬럼의 DISTINCT 값 < 20개
- 후행 컬럼에 선택성 좋은 조건 존재
- INDEX 크기 > 결과 집합 크기

❌ 적용 비권장:
- 누락 컬럼의 DISTINCT 값 > 100개
- 결과 집합이 전체의 30% 이상
- INDEX 자체가 작은 경우 (FULL TABLE SCAN이 더 유리)

🔧 체크포인트:
1. INDEX 컬럼 순서 확인
2. DISTINCT 값 분포 확인  
3. 실행계획에서 "INDEX (SKIP SCAN)" 확인
4. Buffers/Cost 비교 검증
*/

-- 검증: 동일 결과 확인
PROMPT
PROMPT === 결과 동일성 검증 ===

-- 튜닝 전후 결과 건수 비교
WITH before_tuning AS (
    SELECT COUNT(*) AS cnt
    FROM T_ORDER o
    WHERE o.region_code = :B_REGION
      AND o.store_id IN (1, 2, 3, 4, 5)
      AND o.total_amount > 100000
), after_tuning AS (
    SELECT /*+ INDEX_SS(o IDX_ORDER_01) */ COUNT(*) AS cnt
    FROM T_ORDER o
    WHERE o.region_code = :B_REGION
      AND o.store_id IN (1, 2, 3, 4, 5)
      AND o.total_amount > 100000
)
SELECT 
    bt.cnt AS 튜닝전_건수,
    at.cnt AS 튜닝후_건수,
    CASE WHEN bt.cnt = at.cnt THEN 'PASS' ELSE 'FAIL' END AS 검증결과
FROM before_tuning bt, after_tuning at;

SET AUTOTRACE OFF
PROMPT
PROMPT *** Case 01 INDEX SKIP SCAN 실습 완료 ***
PROMPT *** 다음: case_02.sql (적절한 INDEX 선택) ***