# Part 19 튜닝 패턴별 정리

> 📖 출처: **Oracle SQL 실전 튜닝 나침반** — Part 19 튜닝 실무 사례
> 📝 정리: 루나 (2026-03-25)  
> 🎯 **16개 사례를 7가지 튜닝 패턴으로 분류**

---

## 🔍 패턴 분류 개요

| 패턴 | 적용 사례 | 핵심 기법 | 효과 |
|------|----------|----------|------|
| **INDEX 최적화** | Case 01, 02, 12 | INDEX SKIP SCAN, INDEX 힌트, MIN/MAX 유도 | Block I/O 대폭 감소 |
| **JOIN 최적화** | Case 03, 04, 06, 08, 14, 15 | NL↔HASH 변환, JPPD, 순서 변경 | Random I/O → Sequential I/O |
| **서브쿼리 최적화** | Case 05, 09, 10, 16 | 스칼라 서브쿼리, EXISTS 변환 | 반복 ACCESS 제거 |
| **실행 계획 분리** | Case 07, 08 | UNION ALL 분리 | INDEX 활용도 극대화 |
| **반복 ACCESS 제거** | Case 06, 10, 11 | WINDOW 함수, CASE WHEN 통합 | 동일 테이블 중복 SCAN 제거 |
| **페이징 최적화** | Case 12, 13 | 페이징 우선, TOP N 쿼리 | 불필요한 대량 JOIN 방지 |
| **PGA 최적화** | Case 09, 10, 13, 15 | MATERIALIZE, JPPD | 메모리 사용량 최소화 |

---

## 📋 패턴 1: INDEX 최적화

### 적용 사례
- **Case 01**: INDEX SKIP SCAN 활용
- **Case 02**: 적절한 INDEX 선택
- **Case 12**: INDEX FULL SCAN(MIN/MAX) 유도

### 핵심 원리
INDEX 구조와 데이터 분포를 이해하고 최적의 ACCESS PATH를 유도한다.

### 주요 기법

#### 1.1 INDEX SKIP SCAN
```sql
-- 중간 컬럼 누락 시 활용
SELECT /*+ INDEX_SS(T1 IX_TABLE_N1) */ *
FROM 테이블 T1
WHERE 첫번째컬럼 = 값
  AND 세번째컬럼 LIKE 패턴;  -- 두번째컬럼 누락
```

**적용 조건:**
- 누락된 중간 컬럼의 DISTINCT 값이 적음 (≤10개)
- 뒤쪽 컬럼에 유용한 조건 존재
- 전체 테이블 크기가 큼

#### 1.2 INDEX 힌트 지정
```sql
-- 옵티마이저의 잘못된 선택 수정
SELECT /*+ INDEX(테이블 최적INDEX명) */ *
FROM 테이블
WHERE 조건절;
```

**적용 조건:**
- 적절한 INDEX 존재하나 CBO가 선택 안 함
- CLUSTERING FACTOR 양호한 INDEX 우선
- ORDER BY와 INDEX 컬럼이 일치할 때

#### 1.3 TOP N 쿼리 (MIN/MAX 대체)
```sql
-- MAX() 서브쿼리를 TOP N으로 변환
SELECT 컬럼들
FROM (
    SELECT 컬럼들
    FROM 테이블
    WHERE 조건들
    ORDER BY 정렬컬럼 DESC
)
WHERE ROWNUM <= 1;
```

**적용 조건:**
- MIN/MAX에 복합 조건이 있을 때
- PK 또는 UNIQUE INDEX 존재
- INDEX FULL SCAN(MIN/MAX) 실행계획이 안 나올 때

---

## 📋 패턴 2: JOIN 최적화

### 적용 사례
- **Case 03**: NL JOIN → HASH JOIN 변경
- **Case 04**: JPPD 활용
- **Case 06**: JOIN 순서 변경
- **Case 08**: JOIN 순서 + 스칼라 서브쿼리
- **Case 14**: JOIN 순서/방법 최적화
- **Case 15**: JPPD로 인라인뷰 GROUP BY 제거

### 핵심 원리
테이블 크기, 조인 건수, 조건절 선택도를 고려하여 최적의 JOIN 방법과 순서를 결정한다.

### 주요 기법

#### 2.1 NL JOIN ↔ HASH JOIN 변환
```sql
-- 대량 건수 + 작은 테이블 → HASH JOIN
SELECT /*+ USE_HASH(A B) */ 
FROM 큰테이블 A, 작은테이블 B
WHERE A.키 = B.키;

-- 소량 건수 + INDEX 효율적 → NL JOIN  
SELECT /*+ USE_NL(A B) LEADING(A B) */
FROM 선행테이블 A, 후행테이블 B
WHERE A.키 = B.키;
```

**선택 기준:**
| 상황 | 권장 JOIN | 이유 |
|------|----------|------|
| 대량 × 대량 | HASH JOIN | Sequential I/O 효율 |
| 소량 × 대량 | NL JOIN | INDEX 활용 |
| 선택도 좋음 | NL JOIN | 적은 건수만 처리 |
| 선택도 나쁨 | HASH JOIN | 전체 스캔 후 해싱 |

#### 2.2 JPPD (Join Predicate Push Down)
```sql
-- 인라인뷰/VIEW 침투 유도
SELECT /*+ USE_NL(외부 내부) */
FROM 외부테이블,
     (SELECT /*+ NO_MERGE USE_NL(A B) */
      FROM 내부테이블1 A, 내부테이블2 B
      WHERE 조건들) 내부
WHERE 외부.키 = 내부.키;
```

**발생 조건:**
- NL JOIN 사용
- 적은 건수가 VIEW/인라인뷰와 JOIN
- 비용 기반 판단으로 침투 결정

**확인 방법:**
- 실행계획에서 "VIEW PUSHED PREDICATE" 또는 "UNION ALL PUSHED PREDICATE"
- Starts 컬럼이 현저히 줄어든 것

#### 2.3 JOIN 순서 최적화
```sql
-- LEADING 힌트로 순서 제어
SELECT /*+ LEADING(D C A B) USE_NL(C A) USE_HASH(B) */
FROM 테이블A A, 테이블B B, 테이블C C, 테이블D D
WHERE 조건들;
```

**순서 결정 원칙:**
1. **선택도 좋은 테이블** 먼저
2. **작은 테이블** 우선 (HASH JOIN의 Build 테이블)
3. **조건절이 많은 테이블** 먼저
4. **INDEX 효율이 좋은 테이블** 우선

---

## 📋 패턴 3: 서브쿼리 최적화

### 적용 사례
- **Case 05**: JOIN → 스칼라 서브쿼리 변환
- **Case 09**: JPPD로 인라인뷰 침투
- **Case 10**: WINDOW 함수 + EXISTS
- **Case 16**: JOIN 순서/방법 + 서브쿼리 최적화

### 핵심 원리
서브쿼리의 특성(반복성, 캐싱 가능성)을 이해하고 최적의 형태로 변환한다.

### 주요 기법

#### 3.1 JOIN → 스칼라 서브쿼리 변환
```sql
-- UNIQUE KEY JOIN을 스칼라 서브쿼리로
SELECT 
    메인컬럼들,
    (SELECT 참조컬럼 FROM 참조테이블 
     WHERE 메인테이블.키 = 참조테이블.키) AS 참조값
FROM 메인테이블
WHERE 조건들;
```

**적용 조건:**
- **UNIQUE KEY JOIN** (1:1 관계)
- **DISTINCT 값 종류 적음** (≤1000개)
- **OUTER JOIN** 관계
- **대용량 테이블과의 JOIN**

**캐싱 효과:**
- Oracle 내부적으로 스칼라 서브쿼리 결과 캐싱
- 최대 255개까지 (LRU 방식)
- 동일 INPUT에 대해 재실행 안 함

#### 3.2 MAX/MIN 서브쿼리 → EXISTS 변환
```sql
-- BEFORE: 반복 스캔
SELECT *
FROM 테이블 A
WHERE 컬럼 = (SELECT MAX(컬럼) FROM 테이블 B WHERE 조건);

-- AFTER: EXISTS 활용
SELECT *
FROM 테이블 A
WHERE EXISTS (SELECT 1 FROM 테이블 B 
              WHERE 조건 AND B.컬럼 >= A.컬럼)
  AND NOT EXISTS (SELECT 1 FROM 테이블 B 
                  WHERE 조건 AND B.컬럼 > A.컬럼);
```

#### 3.3 COALESCE 활용
```sql
-- UNION 제거를 위한 COALESCE
SELECT 
    COALESCE(
        (SELECT 값1 FROM 테이블1 WHERE 조건1),
        (SELECT 값2 FROM 테이블2 WHERE 조건2),
        (SELECT 값3 FROM 테이블3 WHERE 조건3)
    ) AS 결과값
FROM 기본테이블;
```

---

## 📋 패턴 4: 실행 계획 분리

### 적용 사례
- **Case 07**: 실행 계획 분리 (OPTIONAL 바인드)
- **Case 08**: JOIN 순서 변경 + 스칼라 서브쿼리

### 핵심 원리
조건에 따라 최적의 INDEX를 사용할 수 있도록 UNION ALL로 실행계획을 분리한다.

### 주요 기법

#### 4.1 OPTIONAL 바인드 변수 대응
```sql
-- BEFORE: 함수로 인한 INDEX 사용 불가
SELECT * FROM 테이블
WHERE 컬럼1 = NVL(:바인드1, 컬럼1)
  AND 컬럼2 = DECODE(:바인드2, NULL, 컬럼2, :바인드2);

-- AFTER: 조건별 분리
SELECT * FROM 테이블
WHERE :바인드1 IS NOT NULL AND 컬럼1 = :바인드1

UNION ALL

SELECT * FROM 테이블  
WHERE :바인드1 IS NULL AND :바인드2 IS NOT NULL AND 컬럼2 = :바인드2

UNION ALL

SELECT * FROM 테이블
WHERE :바인드1 IS NULL AND :바인드2 IS NULL;
```

**분리 조건 설계:**
- **상호배타적** 조건 (AND 연산)
- **NULL 체크** 활용
- **각 분기별 최적 INDEX** 존재

#### 4.2 실행계획 분리 원칙
1. **주요 조회 패턴** 파악
2. **패턴별 최적 INDEX** 확인
3. **UNION ALL 분기** 생성
4. **중복 데이터 방지** 확인

---

## 📋 패턴 5: 반복 ACCESS 제거

### 적용 사례
- **Case 06**: EXISTS + JOIN 순서 변경
- **Case 10**: WINDOW 함수 + EXISTS
- **Case 11**: UNION → CASE WHEN 통합

### 핵심 원리
동일 테이블을 여러 번 접근하는 비효율을 제거하여 I/O를 최소화한다.

### 주요 기법

#### 5.1 UNION → CASE WHEN 통합
```sql
-- BEFORE: 반복 스캔
SELECT 컬럼A, 상수1 FROM 테이블 WHERE 조건1
UNION
SELECT 컬럼B, 상수2 FROM 테이블 WHERE 조건2;

-- AFTER: 한 번만 스캔
SELECT 
    CASE WHEN 조건1 THEN 컬럼A WHEN 조건2 THEN 컬럼B END AS 결과,
    CASE WHEN 조건1 THEN 상수1 WHEN 조건2 THEN 상수2 END AS 구분
FROM 테이블
WHERE 조건1 OR 조건2;
```

#### 5.2 WINDOW 함수 활용
```sql
-- BEFORE: MAX 서브쿼리 반복
SELECT * FROM 테이블 WHERE 컬럼 = (SELECT MAX(컬럼) FROM ...);

-- AFTER: WINDOW 함수
SELECT *
FROM (
    SELECT *, 
           ROW_NUMBER() OVER (PARTITION BY 그룹 ORDER BY 정렬컬럼 DESC) AS rn
    FROM 테이블 
    WHERE 조건들
)
WHERE rn = 1;
```

#### 5.3 WITH절 + MATERIALIZE
```sql
-- 동일 데이터 반복 접근 시
WITH 공통데이터 AS (
    /*+ MATERIALIZE */
    SELECT * FROM 대용량테이블 WHERE 공통조건
)
SELECT * FROM 공통데이터 WHERE 추가조건1
UNION ALL
SELECT * FROM 공통데이터 WHERE 추가조건2;
```

---

## 📋 패턴 6: 페이징 최적화

### 적용 사례
- **Case 12**: INDEX FULL SCAN(MIN/MAX) 유도
- **Case 13**: 페이징 후 JOIN + 스칼라 서브쿼리

### 핵심 원리
전체 결과를 만든 후 페이징하지 말고, 먼저 페이징한 후 필요한 데이터만 JOIN한다.

### 주요 기법

#### 6.1 페이징 우선 처리
```sql
-- BEFORE: 전체 JOIN 후 페이징
SELECT *
FROM (
    SELECT 메인.*, 참조.참조컬럼
    FROM 메인테이블 메인, 참조테이블 참조
    WHERE 메인.키 = 참조.키
      AND 조건들
    ORDER BY 정렬컬럼
)
WHERE ROWNUM <= 20;

-- AFTER: 페이징 후 JOIN
SELECT 
    메인.*,
    (SELECT 참조컬럼 FROM 참조테이블 WHERE 키 = 메인.키) AS 참조값
FROM (
    SELECT *
    FROM 메인테이블  
    WHERE 조건들
    ORDER BY 정렬컬럼
    FETCH FIRST 20 ROWS ONLY  -- 또는 WHERE ROWNUM <= 20
) 메인;
```

#### 6.2 TOP N 쿼리 최적화
```sql
-- MAX값을 효율적으로 구하기
SELECT *
FROM (
    SELECT *
    FROM 테이블
    WHERE 조건들
    ORDER BY 기준컬럼 DESC
)
WHERE ROWNUM <= 1;
```

---

## 📋 패턴 7: PGA 최적화

### 적용 사례
- **Case 09**: JPPD로 인라인뷰 침투
- **Case 10**: WINDOW 함수 + EXISTS
- **Case 13**: 페이징 후 JOIN
- **Case 15**: JPPD로 GROUP BY 제거

### 핵심 원리
불필요한 SORT/HASH 연산을 제거하여 PGA 메모리 사용량을 최소화한다.

### 주요 기법

#### 7.1 JPPD로 PGA 사용 제거
```sql
-- 전체 GROUP BY 대신 필요한 부분만
SELECT /*+ 
    OPT_PARAM('_optimizer_push_pred_cost_based' 'false')
    USE_NL(외부 내부)
*/
FROM 외부테이블,
     (SELECT GROUP BY 컬럼들 FROM 내부테이블 내부) 내부
WHERE 외부.키 = 내부.키;
```

#### 7.2 MATERIALIZE 힌트 활용
```sql
WITH 임시테이블 AS (
    /*+ MATERIALIZE */
    SELECT * FROM 대용량테이블 WHERE 공통조건
)
SELECT COUNT(*) FROM 임시테이블;  -- 임시 테이블 생성으로 재사용
```

---

## 🎯 패턴 적용 가이드라인

### 1. 문제 진단 순서
1. **실행계획 분석**: Buffers, Starts, A-Time 확인
2. **병목 지점 파악**: 가장 비싼 Operation 식별
3. **데이터 특성 분석**: 테이블 크기, DISTINCT 값, JOIN 관계
4. **적용 패턴 선택**: 문제 유형에 맞는 패턴 적용

### 2. 패턴 우선순위
1. **INDEX 최적화** (가장 기본적이고 효과적)
2. **JOIN 최적화** (I/O 대폭 감소 가능)
3. **반복 ACCESS 제거** (동일 데이터 중복 방지)
4. **서브쿼리 최적화** (캐싱 효과)
5. **실행 계획 분리** (조건별 최적화)
6. **페이징 최적화** (불필요한 처리 방지)
7. **PGA 최적화** (메모리 효율성)

### 3. 성능 측정 지표
- **Buffer Gets**: 논리적 I/O (핵심 지표)
- **Physical Reads**: 물리적 I/O
- **A-Time**: 실제 소요 시간
- **PGA 사용량**: 메모리 효율성
- **Starts**: 반복 실행 횟수

### 4. 주의사항
- **운영 환경 테스트** 필수
- **통계정보 최신 유지**
- **힌트 남용 금지** (꼭 필요한 경우만)
- **가독성과 유지보수성** 고려

---

## 📊 패턴별 효과 요약

| 패턴 | 주요 개선 지표 | 기대 효과 | 적용 난이도 |
|------|---------------|----------|-------------|
| INDEX 최적화 | Buffer Gets | 90%+ 감소 | ⭐⭐ |
| JOIN 최적화 | I/O, 실행시간 | 80%+ 감소 | ⭐⭐⭐ |
| 서브쿼리 최적화 | Buffer Gets | 50%+ 감소 | ⭐⭐⭐ |
| 실행 계획 분리 | 전체적 개선 | 상황별 상이 | ⭐⭐⭐⭐ |
| 반복 ACCESS 제거 | I/O 횟수 | 50%+ 감소 | ⭐⭐ |
| 페이징 최적화 | JOIN 대상 건수 | 90%+ 감소 | ⭐⭐ |
| PGA 최적화 | 메모리 사용량 | 대폭 감소 | ⭐⭐⭐⭐ |

**난이도 범례:**  
⭐ 매우 쉬움, ⭐⭐ 쉬움, ⭐⭐⭐ 보통, ⭐⭐⭐⭐ 어려움, ⭐⭐⭐⭐⭐ 매우 어려움

> 💡 **핵심**: 복잡해 보이는 SQL도 이 7가지 패턴의 조합이다. 단계별로 접근하면 반드시 최적화할 수 있다!