# Part 16. 파티셔닝 (Partitioning)

> 📖 출처: **Oracle SQL 실전 튜닝 나침반** — Part 16 파티셔닝 (pp.560~642)  
> 📝 정리: 루나 (2026-03-16) - PDF 이미지 텍스트 추출 반영

---

## 목차

| Section | 제목 | 바로가기 |
|---------|------|---------|
| 01 | 개요 | [→](#section-01-개요) |
| 02 | 기본 개념 | [→](#section-02-기본-개념) |
| 03 | 파티셔닝 유형 | [→](#section-03-파티셔닝-유형) |
| 04 | 파티션 KEY 전략 | [→](#section-04-파티션-key-전략) |
| 05 | 파티셔닝 테이블의 INDEX | [→](#section-05-파티셔닝-테이블의-index) |
| 06 | 파티션 관리 | [→](#section-06-파티션-관리) |
| 07 | 파티션 Pruning | [→](#section-07-파티션-pruning) |

---

## Section 01. 개요

### 파티셔닝이란?

대규모 테이블이나 INDEX를 더 작은 조각(파티션)으로 나누어 관리하는 Database 기능이다.

### 파티셔닝의 4가지 장점

| 장점 | 설명 |
|------|------|
| **성능 향상** | 파티션 Pruning으로 필요한 파티션만 SCAN → 응답 시간 향상 |
| **관리 편의성** | 파티션 단위로 추가/삭제/백업 가능 → 유지보수 단순화 |
| **가용성** | 파티션별 독립 관리 → 유지보수 중에도 전체 테이블 가용 |
| **확장성** | 기존 파티션 영향 없이 새 파티션 추가 → 데이터 증가에 유연 |

### 한계와 고려 사항

- 모든 환경에서 최적의 솔루션이 아닐 수 있음
- **잘못된 파티셔닝 설계는 오히려 성능 저하** 초래 가능
- 적절한 파티션 KEY 선택과 유형 결정이 중요
- 성능 테스트와 모니터링을 통한 지속적인 최적화 필요

---

## Section 02. 기본 개념

### 기본 구성 요소

| 요소 | 설명 |
|------|------|
| **파티션 KEY** | 데이터가 어떤 파티션에 저장될지 결정하는 컬럼(또는 컬럼 조합) |
| **파티션 테이블** | 논리적으로 하나이지만 물리적으로 여러 파티션(세그먼트)으로 구성 |
| **LOCAL INDEX** | 파티션별로 생성되는 INDEX |
| **GLOBAL INDEX** | 전체 테이블 데이터를 대상으로 생성되는 INDEX |

### 파티셔닝 아키텍처와 설계 고려사항

#### 파티셔닝과 TABLESPACE의 관계
각 파티션은 별도의 TABLESPACE에 저장될 수 있다. 이를 통해 스토리지 장치를 최적화하고, 데이터 관리 정책을 보다 세밀하게 적용할 수 있다.

#### 파티셔닝과 I/O 성능 최적화
파티셔닝을 통해 데이터 액세스 경로를 최적화하여 디스크 I/O 작업을 줄일 수 있다. 특히, 파티션 Pruning을 통해 필요한 파티션만 읽어오는 방식으로 성능을 개선할 수 있다.

#### 파티셔닝과 병렬 처리 (Parallel Processing)
병렬 처리를 통해 대규모 데이터 처리 시 성능을 극대화할 수 있다. 여러 파티션에 걸쳐 병렬로 쿼리를 실행하거나 데이터를 로드할 수 있다.

#### 파티셔닝 키의 선택
올바른 파티션 KEY의 선택은 파티셔닝 설계에서 가장 중요한 요소 중 하나이다. 파티셔닝 키는 각 행이 저장되는 파티션을 결정하는 하나 이상의 열로 구성된다. Oracle은 파티셔닝 키를 사용하여 INSERT, UPDATE 및 삭제 작업을 적절한 파티션으로 자동으로 안내한다. 잘못된 키 선택은 성능 저하와 관리 복잡도를 증가시킬 수 있다.

#### 파티셔닝 유형 결정
파티셔닝 유형(예: RANGE, HASH, LIST 등)은 데이터 특성과 사용 패턴에 따라 결정된다. 각 유형의 장단점과 적합한 사용 사례를 이해하는 것이 중요하다.

### 언제 파티셔닝을 해야 하는가?

#### 시계열 데이터의 지속적인 증가하는 대용량 데이터
로그, 거래, 센서 등 시간순으로 누적되는 대용량 데이터의 경우, 파티셔닝은 이를 더 작고 관리 가능한 조각으로 나눠 성능을 향상시키고 유지 관리 작업을 용이하게 할 수 있다. 예를 들어 월 단위로 증가하는 사이즈가 2GB 인 경우 RANGE 파티셔닝의 후보가 될 수 있다.

#### 트랜잭션 경합 분산
트랜잭션이 특정 동일 Block에 집중되어 경합으로 트랜잭션 성능이 저하될 수 있는 경우 경합 분산 차원에서 파티셔닝을 고려할 수 있다.

#### 데이터 관리 및 유지보수 작업의 간소화
큰 데이터셋에서 삭제 작업을 실행하는 대신 파티셔닝을 통해서 오래된 파티션을 간단히 삭제가 가능하고 파티션 단위로 작업이 가능하다.

#### 성능 관점에서 파티셔닝이 효과적인 경우
WHERE절에 파티션 KEY가 포함되는 조건 쿼리가 많은 경우 파티션 Pruning으로 전체 테이블 SCAN 대신 필요한 파티션만 SCAN함으로써 응답 속도를 향상시킬 수 있다. 또한 병렬 처리 최적화가 필요한 대규모 처리 환경에서 파티션 단위로 병렬 처리를 통해서 처리 속도를 향상시킬 수 있다.

---

## Section 03. 파티셔닝 유형

### 3가지 기본 파티셔닝 전략

Oracle은 데이터를 개별 파티션에 배치하는 방식을 제어하는 **3가지 기본 데이터 분배 방법**을 제공한다.

| 전략 | 분배 기준 | 적합한 데이터 |
|------|----------|-------------|
| **RANGE Partitioning** | 값의 범위 (날짜, 숫자 등) | 시간 기반, 순차적 데이터 |
| **LIST Partitioning** | 특정 값 목록 (지역, 코드 등) | 이산적 카테고리 데이터 |
| **HASH Partitioning** | 해시 함수로 균등 분배 | 균등 분산 필요, 패턴 없는 데이터 |

이러한 데이터 분배 방법을 사용하여 테이블은 **단일 수준 파티셔닝** 또는 **복합 파티셔닝(Composite)** 테이블로 파티셔닝할 수 있다. 각 파티셔닝 전략은 서로 다른 장점과 설계 고려 사항을 가지고 있다.

---

### 1. RANGE 파티셔닝

특정 컬럼의 값이 **미리 정의된 범위**에 따라 데이터를 분할한다.

**적합한 경우**: 시간 기반 데이터, 순차적 데이터, 데이터 웨어하우스, 롤링 윈도우 작업

```sql
CREATE TABLE SALES
(
  SALE_ID    NUMBER,
  SALE_DATE  DATE,
  AMOUNT     NUMBER
)
PARTITION BY RANGE (SALE_DATE)
(
  PARTITION P_2022 VALUES LESS THAN (TO_DATE('20230101', 'YYYYMMDD')),
  PARTITION P_2023 VALUES LESS THAN (TO_DATE('20240101', 'YYYYMMDD')),
  PARTITION P_2024 VALUES LESS THAN (TO_DATE('20250101', 'YYYYMMDD'))
);
```

**주요 장점**:
- 파티션 Pruning으로 특정 범위 쿼리 성능 향상
- 오래된 파티션 삭제로 데이터 관리 간소화
- 날짜/숫자 범위 필터링 쿼리에 최적

---

### 2. LIST 파티셔닝

데이터가 **특정 고유 값**에 따라 논리적으로 나뉠 때 사용한다.

**적합한 경우**: 지역, 부서, 제품 카테고리, 상태 등 범주형 데이터

```sql
CREATE TABLE CUSTOMERS (
  CUSTOMER_ID   NUMBER,
  CUSTOMER_NAME VARCHAR2(50),
  REGION        VARCHAR2(20)
)
PARTITION BY LIST (REGION) (
  PARTITION P_NORTH VALUES ('NORTH'),
  PARTITION P_SOUTH VALUES ('SOUTH'),
  PARTITION P_EAST  VALUES ('EAST'),
  PARTITION P_WEST  VALUES ('WEST')
);
```

```sql
-- DEFAULT 파티션으로 예상치 못한 값 처리
CREATE TABLE PRODUCTS (
  PRODUCT_ID       NUMBER,
  PRODUCT_NAME     VARCHAR2(100),
  PRODUCT_CATEGORY VARCHAR2(50),
  PRICE            NUMBER
)
PARTITION BY LIST (PRODUCT_CATEGORY) (
  PARTITION ELECTRONICS VALUES ('ELECTRONICS'),
  PARTITION FURNITURE  VALUES ('FURNITURE'),
  PARTITION CLOTHING   VALUES ('CLOTHING'),
  PARTITION OTHER      VALUES (DEFAULT)
);
```

---

### 3. HASH 파티셔닝

HASH 함수를 적용하여 데이터를 **균등하게 분배**한다.

**적합한 경우**: 핫 스팟 방지, 트랜잭션 경합 분산, 병렬 쿼리 처리, Exadata Smart Scan 부하 분산

```sql
CREATE TABLE CUSTOMERS (
  CUSTOMER_ID   NUMBER,
  CUSTOMER_NAME VARCHAR2(50)
)
PARTITION BY HASH (CUSTOMER_ID)
PARTITIONS 4;
```

```sql
-- INDEX Contention 개선: LOCAL INDEX도 8개 HASH 파티셔닝됨
CREATE TABLE USER_ACTIVITY (
  USER_ID       NUMBER,
  ACTIVITY      VARCHAR2(100),
  ACTIVITY_DATE DATE
)
PARTITION BY HASH (USER_ID)
PARTITIONS 8;
```

---

### 복합 파티셔닝 (Composite Partitioning)

두 가지 파티셔닝 방법을 결합하여 더 세밀하게 데이터를 관리한다. 이러한 데이터 분배 방법을 사용하여 테이블은 단일 수준 파티셔닝 또는 복합 파티셔닝 테이블로 파티셔닝 할 수 있다. 각 파티셔닝 전략은 서로 다른 장점과 설계 고려 사항을 가지고 있다.

#### RANGE-HASH (가장 많이 사용)

```sql
CREATE TABLE SALES
(
  SALE_ID     NUMBER,
  SALE_DATE   DATE,
  CUSTOMER_ID NUMBER,
  AMOUNT      NUMBER
)
PARTITION BY RANGE (SALE_DATE)
SUBPARTITION BY HASH (CUSTOMER_ID)
SUBPARTITIONS 4
(
  PARTITION P_2022 VALUES LESS THAN (TO_DATE('20230101', 'YYYYMMDD')),
  PARTITION P_2023 VALUES LESS THAN (TO_DATE('20240101', 'YYYYMMDD')),
  PARTITION P_2024 VALUES LESS THAN (TO_DATE('20250101', 'YYYYMMDD'))
);
-- 총: 3 파티션 × 4 서브파티션 = 12개 세그먼트
```

#### RANGE-LIST (많이 사용)

```sql
CREATE TABLE SALES (
  SALE_ID   NUMBER,
  SALE_DATE DATE,
  REGION    VARCHAR2(20),
  AMOUNT    NUMBER
)
PARTITION BY RANGE (SALE_DATE)
SUBPARTITION BY LIST (REGION)
(
  PARTITION P_2023 VALUES LESS THAN (TO_DATE('20240101', 'YYYYMMDD'))
  (
    SUBPARTITION P_2023_NORTH VALUES ('NORTH'),
    SUBPARTITION P_2023_SOUTH VALUES ('SOUTH')
  ),
  PARTITION P_2024 VALUES LESS THAN (TO_DATE('20250101', 'YYYYMMDD'))
  (
    SUBPARTITION P_2024_NORTH VALUES ('NORTH'),
    SUBPARTITION P_2024_SOUTH VALUES ('SOUTH')
  )
);
```

#### RANGE-RANGE

```sql
CREATE TABLE ORDERS_PT (
  ORDER_ID      NUMBER,
  ORDER_DATE    DATE,
  DELIVERY_DATE DATE,
  CUSTOMER_ID   NUMBER,
  ORDER_AMOUNT  NUMBER
)
PARTITION BY RANGE (ORDER_DATE)
SUBPARTITION BY RANGE (DELIVERY_DATE)
(
  PARTITION P_ORD_202401 VALUES LESS THAN (TO_DATE('20240201', 'YYYYMMDD'))
  (
    SUBPARTITION P_OD_202401_202401 VALUES LESS THAN (TO_DATE('20240201', 'YYYYMMDD')),
    SUBPARTITION P_OD_202401_202402 VALUES LESS THAN (TO_DATE('20240301', 'YYYYMMDD'))
  ),
  PARTITION P_ORD_202402 VALUES LESS THAN (TO_DATE('20240301', 'YYYYMMDD'))
  (
    SUBPARTITION P_OD_202402_202401 VALUES LESS THAN (TO_DATE('20240201', 'YYYYMMDD')),
    SUBPARTITION P_OD_202402_202402 VALUES LESS THAN (TO_DATE('20240301', 'YYYYMMDD'))
  )
);
```

#### LIST-HASH 파티셔닝

데이터를 먼저 리스트(예: 카테고리, 지역)로 파티셔닝하고, 각 LIST 파티션을 해시로 서브파티셔닝한다.

```sql
CREATE TABLE SALES (
  SALE_ID NUMBER,
  REGION VARCHAR2(20),
  CUSTOMER_ID NUMBER,
  AMOUNT NUMBER
)
PARTITION BY LIST (REGION)
SUBPARTITION BY HASH (CUSTOMER_ID)
SUBPARTITIONS 4
(
  PARTITION P_NORTH VALUES ('NORTH'),
  PARTITION P_SOUTH VALUES ('SOUTH')
);
```

#### LIST-RANGE 파티셔닝

데이터를 먼저 리스트(예: 카테고리, 지역)로 파티셔닝하고, 각 LIST 파티션을 범위(예: 시간 또는 숫자 범위)로 서브파티셔닝한다. 특정 카테고리로 데이터를 먼저 나누고, 그 카테고리 내 데이터를 시간 또는 숫자 범위로 다시 세분화하고 싶을 때 유용하다.

```sql
CREATE TABLE SALES (
  SALE_ID NUMBER,
  PRODUCT_ID NUMBER,
  SALE_DATE DATE,
  CATEGORY VARCHAR2(20)
)
PARTITION BY LIST (CATEGORY)
SUBPARTITION BY RANGE (SALE_DATE)
(
  PARTITION P_ELECTRONICS VALUES ('ELECTRONICS')
  (
    SUBPARTITION P_ELEC_2023 VALUES LESS THAN (TO_DATE('20240101', 'YYYYMMDD')),
    SUBPARTITION P_ELEC_2024 VALUES LESS THAN (TO_DATE('20250101', 'YYYYMMDD'))
  ),
  PARTITION P_FURNITURE VALUES ('FURNITURE')
  (
    SUBPARTITION P_FUR_2023 VALUES LESS THAN (TO_DATE('20240101', 'YYYYMMDD')),
    SUBPARTITION P_FUR_2024 VALUES LESS THAN (TO_DATE('20250101', 'YYYYMMDD'))
  )
);
```

#### 기타 조합

위에 정리한 복합 파티셔닝 조합 외에도 HASH-HASH, HASH-LIST, HASH-RANGE, LIST-LIST 등으로도 복합 파티셔닝이 가능하다.

---

### INTERVAL 파티셔닝

RANGE 파티셔닝의 확장형. 데이터 도착 시 **자동으로 새 파티션 생성**.

```sql
CREATE TABLE SALES_ORDERS (
  ORDER_ID    NUMBER,
  ORDER_DATE  DATE,
  CUSTOMER_ID NUMBER,
  ORDER_TOTAL NUMBER
)
PARTITION BY RANGE (ORDER_DATE)
INTERVAL (NUMTOYMINTERVAL(1, 'MONTH'))
(
  PARTITION P_202401 VALUES LESS THAN (TO_DATE('20240201', 'YYYYMMDD'))
);
-- 2024년 2월 데이터 INSERT 시 자동으로 파티션 생성!
```

---

### 가상 열 기반 파티셔닝 (Virtual Column)

물리적으로 저장하지 않는 **파생 컬럼**을 기준으로 파티셔닝.

```sql
CREATE TABLE SALES (
  SALE_ID    NUMBER,
  ORDER_DATE DATE,
  AMOUNT     NUMBER,
  ORDER_YEAR AS (EXTRACT(YEAR FROM ORDER_DATE))  -- 가상 열
)
PARTITION BY RANGE (ORDER_YEAR)
(
  PARTITION P2020 VALUES LESS THAN ('2021'),
  PARTITION P2021 VALUES LESS THAN ('2022'),
  PARTITION P2022 VALUES LESS THAN ('2023')
);
```

```sql
-- 할인 가격 기반 파티셔닝
CREATE TABLE ORDERS (
  ORDER_ID         NUMBER,
  TOTAL_PRICE      NUMBER,
  DISCOUNT         NUMBER,
  DISCOUNTED_PRICE AS (TOTAL_PRICE * (1 - DISCOUNT/100))  -- 가상 열
)
PARTITION BY RANGE (DISCOUNTED_PRICE)
(
  PARTITION P_LOW  VALUES LESS THAN (100),
  PARTITION P_MID  VALUES LESS THAN (500),
  PARTITION P_HIGH VALUES LESS THAN (1000)
);
```

**장점**: 중복 데이터 방지, 유연한 분할 로직, 스키마 복잡성 감소

---

## Section 04. 파티션 KEY 전략

### 핵심 원칙

잘못된 INDEX가 오히려 처리 속도에 나쁜 영향을 미치듯이 무조건 파티션을 한다고 파티션이 가지고 있는 이점을 모두 취할 수 있는 것은 아니다. 성능 향상을 위하여 액세스 유형에 따라 파티셔닝이 이루어질 수 있도록 파티션 KEY를 선정해야 한다. 즉 파티션 KEY 조건이 제대로 사용이 되어야 한다. 데이터 관리의 용이성을 위하여 이력 데이터의 경우에는 생성 주기 또는 소멸 주기가 파티션과 일치하여야 한다. 잘못 정의된 파티션 KEY의 변경은 많은 작업을 수반하기 때문에 초기 설계 시 파티션 KEY를 잘 선정해야 한다.

> 파티션 KEY를 데이터 액세스 패턴과 맞추면 쿼리 성능이 크게 향상되고 리소스 소모가 줄어든다.

### 파티셔닝 유형별 KEY 선택 가이드

#### 파티션 KEY 선택을 위한 일반적인 지침

**가장 자주 쿼리되는 열 식별**
파티션 KEY는 일반적으로 쿼리 필터에서, 특히 WHERE절에서 자주 사용되는 열이어야 한다. 대부분의 쿼리가 특정 열 값을 필터링하는 경우, 그 열이 파티션 KEY로 적합하다. 이 열을 기준으로 파티셔닝하면, Oracle이 파티션 Pruning을 통해 SCAN하는 데이터를 줄여 쿼리 성능을 향상시킬 수 있다.

**데이터의 균등 분포 보장**
파티션 KEY는 모든 파티션에 데이터가 균등하게 분배되도록 선택해야 한다. 파티션 KEY가 데이터의 불균등 분포를 초래하면(예: 특정 파티션에 데이터가 집중되는 경우), 성능 저하와 비효율적인 저장소 사용을 초래할 수 있다. 균등한 데이터 분포는 특정 파티션에 쿼리 부담이 집중되는 "핫스팟"을 방지한다.

**미래의 데이터 성장 고려**
파티션 KEY를 선택할 때 미래의 데이터 성장을 예상해야 한다. 파티셔닝 방식은 지속적인 재조직이나 과도한 유지 관리 없이 데이터 성장을 처리할 수 있을 만큼 유연해야 한다.

**데이터 액세스 패턴 분석**
일반적인 읽기, 쓰기, 삭제 작업에서 데이터가 어떻게 액세스되는지 분석해야 한다. 파티션 KEY를 액세스 패턴과 맞추면 쿼리 성능이 크게 향상되고 리소스 소모가 줄어든다.

**효율적인 데이터 유지 관리를 위한 파티션 KEY 사용**
데이터 유지 관리 작업(예: 오래된 데이터 아카이빙 또는 삭제)을 간소화할 수 있는 파티션 KEY를 선택해야 한다.

| 유형 | 적합한 KEY | 부적합한 KEY |
|------|-----------|-------------|
| **RANGE** | `SALE_DATE`, `ORDER_DATE`, `AMOUNT` 등 연속적 값 | 카테고리 값 |
| **LIST** | `REGION`, `CATEGORY`, `STATUS` 등 고유 유한 값 | 연속적 값 |
| **HASH** | `CUSTOMER_ID`, `ORDER_ID` 등 고유 값이 많은 컬럼 | `GENDER`, `STATUS` 등 고유 값이 적은 컬럼 |

### ⚠️ 파티션 개수 주의

> 일별 데이터 100MB, 일 단위 파티션, 보관 주기 2년이면 파티션 **730개**.
> 파티션 KEY가 없는 INDEX 조회 시 730개 파티션을 각각 ACCESS하는 **오버헤드 발생**.

---

## Section 05. 파티셔닝 테이블의 INDEX

### LOCAL INDEX vs GLOBAL INDEX

Oracle에서는 파티션 테이블에 대해 두 가지 주요 유형의 INDEX를 제공한다. LOCAL INDEX와 GLOBAL INDEX이다. 파티션 테이블의 INDEX 설계 전략도 동일한 파티션 구조로 각 파티션의 데이터를 대상으로 생성되는 LOCAL INDEX와 전체 데이터를 대상으로 생성되는 GLOBAL INDEX로 구분이 된다.

#### LOCAL INDEX (Local Index)

LOCAL INDEX는 테이블과 동일한 방식으로 파티셔닝된 INDEX이다. 즉 INDEX는 테이블 파티션에 맞춰 각 파티션으로 나뉘며, 각 INDEX 파티션은 해당 테이블 파티션에 있는 행만 인덱싱한다.

**특징:**
- INDEX의 각 파티션이 테이블의 파티션에 대응한다
- 테이블의 파티션이 추가되거나 삭제될 때 해당 INDEX 파티션도 자동으로 추가되거나 삭제되어 관리가 쉽다
- 파티션별로 INDEX가 존재하므로, 특정 파티션에서 문제가 발생하면 그 파티션에 대한 INDEX만 재구성하면 된다
- GLOBAL INDEX와 달리 전체 INDEX를 재구성할 필요가 없다
- 파티션 Pruning을 포함하는 쿼리에 적합하며, 쿼리 옵티마이저가 관련된 파티션만 SCAN할 수 있다

| 구분 | LOCAL INDEX | GLOBAL INDEX |
|------|------------|--------------|
| **파티션 구조** | 테이블 파티션과 1:1 대응 | 전체 데이터 대상 (하나의 INDEX) |
| **파티션 관리** | 자동 (추가/삭제 시 연동) | 수동 관리 필요 |
| **재구성 범위** | 특정 파티션만 REBUILD | 전체 INDEX REBUILD |
| **DDL 영향** | 해당 파티션 INDEX만 영향 | 전체 INDEX Unusable 가능 |
| **생성 방법** | `LOCAL` 키워드 포함 | `LOCAL` 키워드 생략 |

### LOCAL INDEX 유형

LOCAL INDEX는 Prefixed INDEX와 Non-Prefixed INDEX로 구분된다. Prefixed INDEX는 파티션 KEY 컬럼이 INDEX의 선행 컬럼으로 지정되는 경우이고 NON-Prefixed INDEX는 파티션 KEY 컬럼이 INDEX의 선두 컬럼이 아니거나 존재하지 않는 경우이다.

#### 로컬 Prefixed INDEX
INDEX 구성이 파티션 KEY 컬럼이 선두인 INDEX

#### 로컬 NON-Prefixed INDEX  
INDEX 구성이 파티션 KEY 컬럼이 선두가 아닌 INDEX

| 유형 | 설명 | 예시 (파티션 KEY: ORDER_DATE) |
|------|------|------|
| **Prefixed** | 파티션 KEY가 INDEX **선두 컬럼** | `(ORDER_DATE, ORDER_MODE, EMPLOYEE_ID)` |
| **Non-Prefixed** | 파티션 KEY가 선두가 **아님** | `(CUSTOMER_ID, ORDER_DATE)` 또는 `(CUSTOMER_ID)` |

#### LOCAL INDEX 설계 전략
INDEX가 PREFIXED, NON-PREFIXED인지가 중요한 것이 아니다. LOCAL INDEX 설계 전략도 Part 05. INDEX 설계 전략에서 다룬 내용과 동일하다.

### LOCAL INDEX 생성 예제

```sql
-- 테이블 생성
CREATE TABLE ORDERS (
  ORDER_ID     VARCHAR2(20),
  ORDER_DATE   DATE,
  ORDER_MODE   VARCHAR2(10),
  CUSTOMER_ID  VARCHAR2(20),
  EMPLOYEE_ID  VARCHAR2(20),
  ORDER_STATUS VARCHAR2(5),
  ORDER_TOTAL  NUMBER
)
TABLESPACE APP_DATA
PARTITION BY RANGE (ORDER_DATE)
(
  PARTITION P_202406 VALUES LESS THAN (TO_DATE('20240701', 'YYYYMMDD')),
  PARTITION P_202407 VALUES LESS THAN (TO_DATE('20240801', 'YYYYMMDD')),
  PARTITION P_202408 VALUES LESS THAN (TO_DATE('20240901', 'YYYYMMDD')),
  PARTITION P_202409 VALUES LESS THAN (TO_DATE('20241001', 'YYYYMMDD')),
  PARTITION P_MAX    VALUES LESS THAN (MAXVALUE)
);
```

```sql
-- PK (LOCAL INDEX) — 반드시 파티션 KEY 포함!
ALTER TABLE ORDERS
ADD CONSTRAINTS IX_ORDERS_PK
PRIMARY KEY(ORDER_ID, ORDER_DATE)
USING INDEX TABLESPACE APP_DATA LOCAL;
```

> ⚠️ **PK, UNIQUE INDEX 생성 시에는 무조건 파티션 KEY가 포함되어 생성되어야 하며 파티션 KEY가 누락되면 에러가 발생한다.**

```sql
-- LOCAL Prefixed INDEX
CREATE INDEX IX_ORDERS_N1
ON ORDERS(ORDER_DATE, ORDER_MODE, EMPLOYEE_ID)
TABLESPACE APP_DATA LOCAL;
```

```sql
-- LOCAL Non-Prefixed INDEX
CREATE INDEX IX_ORDERS_N2
ON ORDERS(CUSTOMER_ID, ORDER_DATE)
TABLESPACE APP_DATA LOCAL;
```

### Non-Prefixed INDEX 성능 비교

IX_ORDERS_N1 INDEX는 LOCAL Prefixed INDEX이며 IX_ORDERS_N2, IX_ORDERS_N3은 LOCAL NON-Prefixed INDEX이다. IX_ORDERS_N3의 경우에는 파티션 KEY 컬럼인 ORDER_DATE가 제외되어 생성되었다.

조회 범위가 만약 ORDER_DATE 특정 월에 대한 한 달 범위로 들어온다면 IX_ORDERS_N2, IX_ORDERS_N3 INDEX 사용으로 인한 I/O 발생량은 INDEX 사이즈가 작은 IX_ORDERS_N3를 사용했을 때가 더 나올 수도 있다.

**특정 월 한 달을 조회 시에 IX_ORDERS_N2, IX_ORDERS_N3를 사용했을 때 I/O 발생량:**
LOCAL INDEX이기 때문에 해당 월 파티션 전체를 조회하므로 I/O 발생량이 동일함을 알 수 있다.

그런데 만약 조회 범위가 월 전체가 아닌 7일 정도로 발생했다면 IX_ORDERS_N3의 경우는 해당 월 파티션 전체 데이터가 조회되기 때문에 당연히 IX_ORDERS_N2를 사용하는 경우에 I/O 발생량이 더 낮다.

| 조회 범위 | IX_N2 (CUSTOMER_ID, ORDER_DATE) | IX_N3 (CUSTOMER_ID) |
|-----------|------|------|
| **월 전체** | Buffers=20 | Buffers=20 (동일) |
| **7일** | **Buffers=5** ✅ | Buffers=20 (비효율) |

> 조회 범위가 좁아질수록 **파티션 KEY를 포함한 INDEX**가 유리하다.

### GLOBAL INDEX

```sql
-- LOCAL 키워드를 생략하면 GLOBAL INDEX
CREATE INDEX IX_ORDERS_N2
ON ORDERS(CUSTOMER_ID)
TABLESPACE APP_DATA;
```

GLOBAL INDEX는 전체 테이블 데이터를 대상으로 생성되는 INDEX로, 파티션 구조와 독립적으로 관리된다.

**GLOBAL INDEX 사용 시 고려사항:**
- 파티션 DROP/TRUNCATE 시 **INDEX가 Unusable** → 장애 위험
- `SKIP_UNUSABLE_INDEXES = TRUE` 설정으로 DML 실패 방지 가능
- 대용량 Hot 테이블에서는 **사용 주의**
- 파티션 관리 작업 시 전체 INDEX에 영향을 미칠 수 있음

### DDL 작업별 INDEX Unusable 관계

파티션 테이블에 대한 DDL 작업이 LOCAL INDEX와 GLOBAL INDEX에 미치는 영향이 다르다. LOCAL INDEX는 해당 파티션에만 영향을 미치지만, GLOBAL INDEX는 전체 INDEX가 영향을 받을 수 있다.

| DDL 작업 | LOCAL INDEX | GLOBAL INDEX |
|----------|-------------|--------------|
| **ADD** | 새로 생성 → 무관 | 무관 |
| **DROP** | 같이 삭제 → 무관 | ⚠️ Unusable |
| **TRUNCATE** | 데이터 없음 → 무관 | ⚠️ Unusable |
| **SPLIT** | 해당 파티션 Unusable | ⚠️ Unusable |
| **MERGE** | 합쳐진 파티션 Unusable | ⚠️ Unusable |
| **MOVE** | 해당 파티션 Unusable | ⚠️ Unusable |
| **EXCHANGE** | 해당 파티션 Unusable | ⚠️ Unusable |
| **RENAME** | 무관 | 무관 |

이러한 특성 때문에 파티션 테이블에서는 **LOCAL INDEX 사용을 권장**한다.

---

## Section 06. 파티션 관리

### RANGE 파티션 관리

#### 파티션 추가 (ADD)

```sql
-- 단일 추가
ALTER TABLE ORDERS
ADD PARTITION P_202412 VALUES LESS THAN (TO_DATE('20250101', 'YYYYMMDD'));

-- 복수 추가
ALTER TABLE ORDERS
ADD PARTITION P_202412 VALUES LESS THAN (TO_DATE('20250101', 'YYYYMMDD')),
    PARTITION P_202501 VALUES LESS THAN (TO_DATE('20250201', 'YYYYMMDD')),
    PARTITION P_202502 VALUES LESS THAN (TO_DATE('20250301', 'YYYYMMDD'));
```

> ⚠️ **MAXVALUE 파티션이 존재하면 ADD 불가** → SPLIT 사용!

#### 파티션 삭제 (DROP)

```sql
ALTER TABLE ORDERS DROP PARTITION P_202406;

-- 복수 삭제
ALTER TABLE ORDERS DROP PARTITION P_202406, P_202407;

-- GLOBAL INDEX 유지하면서 삭제
ALTER TABLE ORDERS DROP PARTITION P_202406 UPDATE GLOBAL INDEXES;
```

#### 파티션 비우기 (TRUNCATE)

```sql
ALTER TABLE ORDERS TRUNCATE PARTITION P_202407;

-- GLOBAL INDEX 유지
ALTER TABLE ORDERS TRUNCATE PARTITION P_202407 UPDATE GLOBAL INDEXES;
```

> Redo/Undo 최소화 → DELETE보다 훨씬 빠름

#### 파티션 이동 (MOVE)

```sql
ALTER TABLE ORDERS
MOVE PARTITION P_202401 TABLESPACE APP_DATA PARALLEL 2 ONLINE COMPRESS NOLOGGING;
```

> ⚠️ **MOVE 후 반드시 LOCAL INDEX REBUILD 필요!**

```sql
-- MOVE 후 반드시 LOCAL INDEX REBUILD!
ALTER INDEX IX_ORDERS_PK REBUILD PARTITION P_202410
TABLESPACE APP_DATA PARALLEL 2 NOLOGGING ONLINE;

ALTER INDEX IX_ORDERS_N1 REBUILD PARTITION P_202410
TABLESPACE APP_DATA PARALLEL 2 NOLOGGING ONLINE;
```

#### 파티션 교환 (EXCHANGE) — 가용성 우수 ✅

MOVE보다 **가용성이 월등히 좋음** (눈 깜짝할 사이에 EXCHANGE)

EXCHANGE는 파티션과 비파티션 테이블 간의 데이터와 INDEX를 교환하는 작업으로, 물리적 데이터 이동 없이 메타데이터만 변경하므로 매우 빠르다.

```sql
-- Step 1: 임시 테이블 생성 (압축, NOLOGGING)
CREATE TABLE TEMP_ORDERS_P_202408
TABLESPACE APP_DATA NOLOGGING COMPRESS
AS SELECT * FROM ORDERS PARTITION(P_202408);

ALTER TABLE TEMP_ORDERS_P_202408 LOGGING;

-- Step 2: 동일 구조 INDEX 생성
ALTER TABLE TEMP_ORDERS_P_202408
ADD CONSTRAINTS IX_TEMP_ORDERS_P_202408_PK
PRIMARY KEY(ORDER_ID, ORDER_DATE)
USING INDEX TABLESPACE APP_DATA NOLOGGING;

CREATE INDEX IX_TEMP_ORDERS_P_202408_N1
ON TEMP_ORDERS_P_202408(ORDER_DATE, ORDER_MODE, EMPLOYEE_ID)
TABLESPACE APP_DATA NOLOGGING;

-- Step 3: EXCHANGE 실행!
ALTER TABLE ORDERS
EXCHANGE PARTITION P_202408 WITH TABLE TEMP_ORDERS_P_202408
INCLUDING INDEXES WITHOUT VALIDATION;
```

| EXCHANGE 옵션 | 설명 |
|---------------|------|
| `WITHOUT VALIDATION` | 유효성 체크 생략 (빠름) |
| `WITH VALIDATION` | 유효성 체크 (데이터 건수에 비례하여 느려짐) |
| `INCLUDING INDEXES` | INDEX 포함 EXCHANGE |

#### 파티션 분할 (SPLIT)

```sql
-- 기존 파티션을 날짜 기준으로 분할
ALTER TABLE ORDERS
SPLIT PARTITION P_202409 AT (TO_DATE('20240915', 'YYYYMMDD'))
INTO (PARTITION P_202409_H1, PARTITION P_202409_H2);

-- MAXVALUE 파티션 SPLIT으로 새 파티션 추가
ALTER TABLE ORDERS
SPLIT PARTITION P_MAX AT (TO_DATE('20250101', 'YYYYMMDD'))
INTO (PARTITION P_202412, PARTITION P_MAX);
```

#### 파티션 병합 (MERGE)

```sql
ALTER TABLE ORDERS
MERGE PARTITIONS P_ONLINE, P_OFFLINE INTO PARTITION P_DIGITAL;
```

---

### LIST 파티션 관리

```sql
-- 추가 (DEFAULT 없을 때만 ADD 가능)
ALTER TABLE ORDERS ADD PARTITION P_PHONE VALUES ('PHONE');

-- DEFAULT 파티션 존재 시 → SPLIT 사용
ALTER TABLE ORDERS
SPLIT PARTITION P_DEFAULT VALUES ('APP')
INTO (PARTITION P_DEFAULT, PARTITION P_APP);
```

### 복합 파티션 서브파티션 관리

```sql
-- 서브파티션 추가
ALTER TABLE ORDERS
MODIFY PARTITION P_ONLINE
ADD SUBPARTITION P_ONLINE_SP_202406
VALUES LESS THAN (TO_DATE('20240701', 'YYYYMMDD'));

-- 서브파티션 MOVE
ALTER TABLE ORDERS
MOVE SUBPARTITION P_ONLINE_SP_202402
TABLESPACE APP_DATA PARALLEL 2 COMPRESS NOLOGGING;

-- 서브파티션 EXCHANGE
ALTER TABLE ORDERS
EXCHANGE SUBPARTITION P_ONLINE_SP_202402
WITH TABLE TEMP_ORDERS_P_ONLINE_SP_202402
INCLUDING INDEXES WITHOUT VALIDATION;

-- 서브파티션 SPLIT
ALTER TABLE ORDERS
SPLIT SUBPARTITION P_ONLINE_SP_MAX AT (TO_DATE('20240501', 'YYYYMMDD'))
INTO (SUBPARTITION P_ONLINE_SP_202405, SUBPARTITION P_ONLINE_SP_MAX);

-- 서브파티션 MERGE
ALTER TABLE ORDERS
MERGE SUBPARTITIONS P_ONLINE_SP_202401, P_ONLINE_SP_202402
INTO SUBPARTITION P_ONLINE_SP_202402;
```

### 관리 작업 비교 요약

| 작업 | 목적 | 가용성 영향 | INDEX REBUILD |
|------|------|-----------|---------------|
| **MOVE** | TABLESPACE 이동/재구성 | ❌ 작업 중 사용 불가 | ✅ 필요 |
| **EXCHANGE** | 비파티션 테이블과 교환 | ✅ **순간적** | ❌ 불필요 |
| **SPLIT** | 파티션 분할 | ⚠️ 물리적 분할 시 | ✅ 필요 |
| **MERGE** | 파티션 병합 | ⚠️ 물리적 병합 시 | ✅ 필요 |

---

## Section 07. 파티션 Pruning

### 개념

쿼리 실행 시 **WHERE절의 파티션 KEY를 기준**으로 필요한 파티션만 검색하고 나머지는 건너뛰는 최적화 기법.

### RANGE 파티션 Access Pattern (4가지)

Oracle은 쿼리의 WHERE절 조건을 분석하여 필요한 파티션만 SCAN하도록 최적화한다. 이를 통해 I/O를 크게 줄이고 성능을 향상시킬 수 있다.

> 테스트 환경: 월 단위 RANGE 파티션, 파티션당 약 300만 건, 총 약 3,600만 건

#### 1. PARTITION RANGE SINGLE — 1개 파티션만 SCAN

```sql
SELECT CUSTOMER_ID, ORDER_MODE, COUNT(*) AS CNT
  FROM ORDERS
 WHERE ORDER_DATE >= TO_DATE('20240601', 'YYYYMMDD')
   AND ORDER_DATE <  TO_DATE('20240701', 'YYYYMMDD')
 GROUP BY CUSTOMER_ID, ORDER_MODE;
```

```
PARTITION RANGE SINGLE  →  Starts=1, Buffers=19,053
```

#### 2. PARTITION RANGE ITERATOR — 연속 복수 파티션 순회

```sql
SELECT CUSTOMER_ID, ORDER_MODE, COUNT(*) AS CNT
  FROM ORDERS
 WHERE ORDER_DATE >= TO_DATE('20240601', 'YYYYMMDD')
   AND ORDER_DATE <  TO_DATE('20240901', 'YYYYMMDD')
 GROUP BY CUSTOMER_ID, ORDER_MODE;
```

```
PARTITION RANGE ITERATOR  →  Starts=3, Buffers=58,425
```

#### 3. PARTITION RANGE INLIST — IN 조건 기반

```sql
SELECT CUSTOMER_ID, ORDER_MODE, COUNT(*) AS CNT
  FROM ORDERS A
 WHERE ORDER_DATE IN (TO_DATE('20240120 132339', 'YYYYMMDDHH24MISS'),
                      TO_DATE('20240120 232241', 'YYYYMMDDHH24MISS'))
 GROUP BY CUSTOMER_ID, ORDER_MODE;
```

```
PARTITION RANGE INLIST  →  Starts=1, Buffers=19,560
```

#### 4. PARTITION RANGE ALL — ⚠️ 전체 파티션 SCAN

```sql
-- 파티션 KEY 조건이 없거나 Pruning 불가 시
PARTITION RANGE ALL  →  Starts=13, Buffers=230,000
```

### 성능 비교 요약

| Access Pattern | 파티션 수 | Buffers | 비고 |
|----------------|----------|---------|------|
| **SINGLE** | 1개 | 19,053 | ✅ 가장 효율적 |
| **ITERATOR** | 3개 | 58,425 | 범위 비례 |
| **INLIST** | 1개 | 19,560 | IN 조건 |
| **ALL** | 13개 (전체) | 230,000 | ❌ 최악 |

> ⚠️ PARTITION RANGE ALL이 빈번하면 **파티션 KEY를 잘못 설정한 것은 아닌지 검토** 필요!

---

### PARTITION RANGE JOIN-FILTER

HASH JOIN 시 선행 테이블의 JOIN 조건에 해당하는 파티션만 SCAN하도록 최적화하는 고급 파티션 Pruning 기법이다.

```sql
SELECT A.CUSTOMER_ID, A.ORDER_MODE, COUNT(*) AS CNT
  FROM ORDERS A, STD_DATE B
 WHERE A.ORDER_DATE = B.ORDER_DATE
   AND B.ID = 10
 GROUP BY A.CUSTOMER_ID, A.ORDER_MODE;
```

```
PARTITION RANGE JOIN-FILTER  →  1개 파티션만 SCAN (HASH JOIN 시에만 나타남)
```

이는 JOIN 조건을 이용해 동적으로 파티션을 필터링하는 방식으로, 복잡한 JOIN 쿼리에서도 효과적인 파티션 Pruning을 가능하게 한다.

---

### 복합 파티션 Access Pattern

복합 파티셔닝에서는 주 파티션과 서브파티션 각각에 대해 Pruning이 적용된다. 이는 더욱 세밀한 데이터 접근을 가능하게 한다.

| 실행 계획 | 설명 |
|-----------|------|
| `PARTITION RANGE SINGLE + PARTITION LIST ALL` | 1개월 파티션 + 전체 서브파티션 |
| `PARTITION RANGE ITERATOR + PARTITION LIST SINGLE` | 복수 월 + 특정 서브파티션 |
| `PARTITION RANGE ALL + PARTITION LIST INLIST` | 전체 월 + IN 조건 서브파티션 |
| `PARTITION RANGE JOIN-FILTER + PARTITION LIST SINGLE` | JOIN 필터 + 특정 서브파티션 |

복합 파티셔닝에서는 각 레벨에서의 Pruning이 결합되어 최종적으로 SCAN되는 데이터 양이 결정된다.

---

### 파티션 테이블 JOIN 핵심 ⭐

#### NESTED LOOP JOIN — 파티션 KEY 없으면 성능 급격 악화

```sql
-- ❌ BAD: 파티션 KEY 없이 JOIN → 전체 파티션 SCAN
SELECT /*+ LEADING(A B) USE_NL(B) */
       A.ORDER_MODE, B.PRODUCT_ID, COUNT(*) AS CNT, SUM(QUANTITY) AS QUANTITY
  FROM ORDERS A, ORDER_ITEMS B
 WHERE A.ORDER_ID = B.ORDER_ID                      -- ORDER_ID만으로 JOIN
   AND A.ORDER_DATE >= TO_DATE('20240101', 'YYYYMMDD')
   AND A.ORDER_DATE <  TO_DATE('20240102', 'YYYYMMDD')
 GROUP BY A.ORDER_MODE, B.PRODUCT_ID;
-- PARTITION RANGE ALL → Starts=133K, Buffers=402K
```

```sql
-- ✅ GOOD: 파티션 KEY를 JOIN 조건에 추가
SELECT /*+ LEADING(A B) USE_NL(B) */
       A.ORDER_MODE, B.PRODUCT_ID, COUNT(*) AS CNT, SUM(QUANTITY) AS QUANTITY
  FROM ORDERS A, ORDER_ITEMS B
 WHERE A.ORDER_ID = B.ORDER_ID
   AND A.ORDER_DATE = B.ORDER_DATE                  -- 파티션 KEY 추가!
   AND A.ORDER_DATE >= TO_DATE('20240101', 'YYYYMMDD')
   AND A.ORDER_DATE <  TO_DATE('20240102', 'YYYYMMDD')
 GROUP BY A.ORDER_MODE, B.PRODUCT_ID;
-- PARTITION RANGE SINGLE → Buffers=5,240 (약 1/77로 감소!)
```

> **NL JOIN에서 파티션 KEY가 없으면**: 선행 데이터 건수 × 파티션 개수만큼 I/O 급증

#### 파티션 KEY가 다를 때 — 날짜 규칙성 활용

파티션 KEY(`END_DATE`)와 조회 조건(`ORDER_DATE`)이 다를 때, 날짜 간 규칙성 확인:

```sql
-- 규칙성 확인 (최대 -30일 ~ +30일 차이)
SELECT TRUNC(ORDER_DATE - END_DATE) AS DIFF_DAY, COUNT(*) AS CNT
  FROM ORDER_ITEMS
 GROUP BY TRUNC(ORDER_DATE - END_DATE)
 ORDER BY 1;
```

```sql
-- 규칙성을 활용한 파티션 KEY 범위 추가
SELECT /*+ LEADING(A B) USE_NL(B) */
       A.ORDER_MODE, B.PRODUCT_ID, COUNT(*) AS CNT, SUM(QUANTITY) AS QUANTITY
  FROM ORDERS A, ORDER_ITEMS B
 WHERE A.ORDER_ID = B.ORDER_ID
   AND A.ORDER_DATE = B.ORDER_DATE
   AND A.ORDER_DATE >= TO_DATE('20240101', 'YYYYMMDD')
   AND A.ORDER_DATE <  TO_DATE('20240102', 'YYYYMMDD')
   AND B.END_DATE >= TO_DATE('20240101', 'YYYYMMDD') - 31   -- 규칙성 활용!
   AND B.END_DATE <  TO_DATE('20240102', 'YYYYMMDD') + 31
 GROUP BY A.ORDER_MODE, B.PRODUCT_ID;
-- PARTITION RANGE ALL → PARTITION RANGE ITERATOR (Starts 138K → 16K)
```

#### HASH JOIN — 파티션 와이즈 JOIN

```sql
-- ❌ 파티션 KEY 조건 각각 → 각각 PARTITION RANGE ITERATOR
SELECT /*+ LEADING(A B) USE_HASH(B) */
       A.ORDER_MODE, B.PRODUCT_ID, COUNT(*), SUM(QUANTITY)
  FROM ORDERS A, ORDER_ITEMS B
 WHERE A.ORDER_ID = B.ORDER_ID
   AND A.ORDER_DATE >= TO_DATE('20240101', 'YYYYMMDD')
   AND A.ORDER_DATE <  TO_DATE('20240701', 'YYYYMMDD')
   AND B.ORDER_DATE >= TO_DATE('20240101', 'YYYYMMDD')  -- 각각 조건
   AND B.ORDER_DATE <  TO_DATE('20240701', 'YYYYMMDD')
 GROUP BY A.ORDER_MODE, B.PRODUCT_ID;
-- PGA 메모리: 64MB
```

```sql
-- ✅ 파티션 KEY를 JOIN 조건으로 → 파티션 와이즈 JOIN!
SELECT /*+ LEADING(A B) USE_HASH(B) */
       A.ORDER_MODE, B.PRODUCT_ID, COUNT(*), SUM(QUANTITY)
  FROM ORDERS A, ORDER_ITEMS B
 WHERE A.ORDER_ID = B.ORDER_ID
   AND A.ORDER_DATE = B.ORDER_DATE                      -- JOIN 조건으로!
   AND A.ORDER_DATE >= TO_DATE('20240101', 'YYYYMMDD')
   AND A.ORDER_DATE <  TO_DATE('20240701', 'YYYYMMDD')
 GROUP BY A.ORDER_MODE, B.PRODUCT_ID;
-- PGA 메모리: 12MB (1/5.2로 감소!)
-- 파티션 단위로 쪼개서 JOIN → 메모리 효율적
```

> 부모-자식 테이블이 **동일 파티션 KEY로 구성**되고 **동일 KEY로 JOIN**되면 → **파티션 와이즈 JOIN**으로 PGA 메모리와 I/O 모두 최적화!

---

## 핵심 체크리스트 ✅

1. **파티션 KEY** = 가장 자주 WHERE절에 사용되는 컬럼
2. **파티션 수** = 너무 적으면 세분화 부족, 너무 많으면 오버헤드
3. **LOCAL INDEX 우선** = GLOBAL INDEX는 DDL 시 Unusable 위험
4. **PK에 파티션 KEY 포함** = LOCAL INDEX 생성 필수 조건
5. **JOIN 시 파티션 KEY 추가** = NL JOIN에서 I/O 급증 방지
6. **EXCHANGE > MOVE** = 가용성이 중요하면 EXCHANGE 선택
7. **PARTITION RANGE ALL 빈번** = 파티션 KEY 재검토 필요
