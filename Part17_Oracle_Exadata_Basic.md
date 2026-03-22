# Part 17. Oracle Exadata Basic 요약

> 📖 출처: Oracle SQL 실전 튜닝 나침반 (Part 17, pp.645-723)
> 📝 정리: 루나 (2026-03-16)

---

## 목차

1. [Section 01. Exadata 개요](#section-01-exadata-개요)
2. [Section 02. 오프로딩 (Offloading)](#section-02-오프로딩)
3. [Section 03. Storage Index](#section-03-storage-index)
4. [Section 04. HCC (Hybrid Columnar Compression)](#section-04-hcc)
5. [Section 05. Smart Flash Cache (ESFC)](#section-05-smart-flash-cache)
6. [Section 06. 병렬처리 (Parallel Execution)](#section-06-병렬처리)
7. [Section 07. Exadata 개발 시 고려사항](#section-07-개발-시-고려사항)

---

## Section 01. Exadata 개요

### Exadata란?
- DB Server + Storage Server 간 통신으로 **I/O를 줄이는 Engineered System**
- Hardware + Software 통합 → 고성능, 고가용성, 확장성
- OLTP + OLAP + 혼합 워크로드 모두 최적화
- X3-2 모델 ~ 현재 X10M까지 출시

### 주요 구성
- **DB Server**: Oracle Database 실행 (19cR2/ASM)
- **Cell Server (Storage Server)**: OS(CPU/Memory) + Storage Software
- 구성 비율: DB 1대 : Cell 7대 / DB 2대 : Cell 28대

### Exadata 핵심 기능
| 기능 | 설명 |
|------|------|
| **Smart Scan** | Cell Server에서 필요한 데이터만 선별하여 DB로 전송 |
| **Storage Index** | 컬럼 최소/최대값 메타데이터로 불필요한 I/O 제거 |
| **HCC** | Hybrid Columnar Compression, 최대 10배+ 압축 |
| **Flash Cache** | 고성능 플래시 기반 캐싱 (OLTP Single Block I/O 향상) |
| **IORM** | I/O Resource Manager |
| **InfiniBand** | 고속 네트워크 인터커넥트 |

---

## Section 02. 오프로딩

### 오프로딩(Offloading) 정의
- DB 서버 작업을 **Storage 계층에서 처리**하여 필요한 데이터만 DB로 전송
- 목적: DB 서버 CPU 사용량 감소, 디스크 액세스 감소

### Smart Scan vs 오프로딩
- **Smart Scan**: 오프로딩을 위한 기술 (SQL 구문 최적화 중점)
- **오프로딩**: Smart Scan + 블룸 필터 + 함수 오프로딩 등 포괄 개념

### Smart Scan 주요 기능

#### 1) 컬럼 프로젝션 (Column Projection)
- SELECT절에 기술한 **필요한 컬럼만** DB 서버로 반환
- 2개 컬럼 조회가 100개 컬럼보다 월등히 빠름
- → **SELECT * 지양, 필요 컬럼만 기술**

#### 2) Predicate 필터링
- WHERE절 조건으로 **Storage에서 불필요한 데이터 제거**
- 기존: DB에서 Block 읽은 후 필터 → Exadata: Storage에서 필터

#### 3) Storage Index
- 스토리지 영역 내 컬럼의 **최소값/최대값** 메타데이터 유지
- 파티션 Pruning과 유사한 방식

#### 4) 심플 JOIN (블룸 필터, Bloom Filter)
- Storage에서 **JOIN에 필요한 데이터만** DB로 반환
- HASH JOIN에서만 동작
- 선행 테이블 DISTINCT 값이 적을 때 효과 극대화
- 실행계획: `JOIN FILTER CREATE` / `JOIN FILTER USE`

#### 5) 함수 오프로딩
- Oracle 내장 함수(MOD, TRIM, UPPER, TO_CHAR 등)의 오프로딩 지원
- 확인: `SELECT DISTINCT NAME, VERSION, OFFLOADABLE FROM V$SQLFN_METADATA`

### ⚠️ Smart Scan 전제 조건
1. **Full Scan (Multi Block I/O)** 필수
2. **Direct Path Read** 필수
3. 데이터는 Exadata Storage에 저장
4. IOT, Clustered Table **불가**
5. Row Dependencies 활성화 시 **불가**
6. Storage Server 과부하 시 **불가**

### Smart Scan 비활성화 케이스
- INDEX 사용 시
- WHERE절 사용자 정의 함수
- 절차형 코드 (행 단위 처리)
- Chained Row 발생 시 → Block 전송 모드로 복귀
- OLTP성 SQL (실행 수 높고 조회 범위 좁은 경우)

### Smart Scan 모니터링

#### SQL Monitor
```sql
-- 5초 이상 수행 / Parallel / /*+ MONITOR */ 힌트 SQL 모니터링
SELECT DBMS_SQLTUNE.REPORT_SQL_MONITOR(
  SQL_ID => 'sql_id', report_level => 'ALL') AS TEXT
FROM DUAL;
```
- **Cell Offload 값**: Smart Scan 비율 (높을수록 좋음)
- 최신 버전에서는 HCC 압축 포함하여 1,000% 이상 가능

#### GV$SQL로 확인
```sql
SELECT SQL_ID,
  CASE WHEN IO_CELL_OFFLOAD_ELIGIBLE_BYTES = 0 THEN 0
  ELSE ROUND((IO_CELL_OFFLOAD_ELIGIBLE_BYTES - IO_INTERCONNECT_BYTES)
    / IO_CELL_OFFLOAD_ELIGIBLE_BYTES, 4) END * 100 AS OFFLOAD_RATE
FROM GV$SQL
WHERE SQL_ID = 'target_sql_id';
```

### 성능 비교 (실측)
| 시나리오 | Smart Scan OFF | Smart Scan ON | 개선 |
|----------|---------------|--------------|------|
| Column Projection | 38.91초 | 26.86초 | 31% |
| Predicate 필터링 | 12.14초 | 0.31초 | **97%** |
| 블룸 필터 (JOIN) | 59.12초 | 2.99초 | **95%** |

---

## Section 03. Storage Index

### 개요
- Exadata Storage 서버에 **자동 생성**되는 최소/최대값 메타데이터
- 쿼리 조건에 포함되지 않는 데이터 Block의 **디스크 I/O를 제거**
- 파티션 Pruning과 유사한 원리

### 특징
- 테이블당 **최대 8개 컬럼**에 1MB당 1개 Index 유지
- 자동(Automatic) + 투명(Transparent) 관리
- 사용자가 직접 생성 불가
- 디스크에 영구 보관 안 됨 → cellsrv 재시작 시 재생성
- 최초 Smart Scan 시 생성

### 사용 가능 조건
- Smart Scan 발생 + 하나 이상의 조건절
- 비교 연산자: `=, <, >, BETWEEN, >=, <=, IN, IS NULL, IS NOT NULL`
- JOIN, 병렬처리, HCC, Bind 변수, 파티션, 서브쿼리

### 사용 불가
- CLOB
- 부정형 비교 (`!=`, `<>`)
- 와일드카드 (`LIKE '%'`)
- WHERE절 사용자 정의 함수

### 모니터링
```sql
-- Storage Index 절감 통계
SELECT * FROM V$SYSSTAT
WHERE NAME = 'cell physical IO bytes saved by storage index';
```
- `_kcfis_storageidx_disabled` = true/false 로 ON/OFF 테스트 가능

---

## Section 04. HCC

### Oracle 압축 메커니즘 종류

| 압축 방식 | 버전 | 특징 |
|-----------|------|------|
| **BASIC** | 9i~ | Direct Path Write만 압축, Block 단위 |
| **OLTP** | 11g~ | 모든 DML 압축, PCTFREE 10% 유지 |
| **HCC** | Exadata 전용 | Compression Unit(CU) 단위 컬럼 압축 |

### HCC 압축 레벨

| 레벨 | 알고리즘 | 예상 압축률 | 특징 |
|------|----------|-----------|------|
| **QUERY LOW** | LZO | 4x | CPU 최소, 속도 우선 |
| **QUERY HIGH** | ZLIB(gzip) | 6x | **밸런스 최적** |
| **ARCHIVE LOW** | ZLIB(고압축) | 7x | 높은 압축률 |
| **ARCHIVE HIGH** | Bzip2 | 12x | 최고 압축, CPU 집약적 |

### HCC Syntax
```sql
-- 테이블 생성 시
CREATE TABLE t1 ... COMPRESS FOR QUERY HIGH;

-- 기존 테이블 정의 변경
ALTER TABLE t1 COMPRESS FOR QUERY HIGH;

-- 데이터까지 변경 (MOVE)
ALTER TABLE t1 MOVE COMPRESS FOR QUERY HIGH PARALLEL 32;

-- 특정 파티션만
ALTER TABLE t1 MOVE PARTITION p1 COMPRESS FOR QUERY HIGH PARALLEL 32;
```

### HCC 메커니즘
- **Compression Unit (CU)**: 논리적 구조, 여러 Oracle Block으로 구성 (보통 32K/64K)
- CU 내에서 **컬럼 베이스**로 데이터 재구성 (Row + Column 혼합 방식)

### 성능 비교 (8,600MB 데이터 기준)

#### 적재 성능
| 압축방식 | 사이즈(MB) | 압축률 | 적재시간(초) |
|----------|-----------|--------|------------|
| NONE | 8,616 | - | 54 |
| QUERY LOW | 936 | 9.21x | 122 |
| **QUERY HIGH** | **472** | **17.25x** | **243** |
| ARCHIVE LOW | 464 | 17.57x | 306 |
| ARCHIVE HIGH | 408 | 21.12x | 1,024 |

#### 쿼리 성능 (I/O 집약적)
| 압축방식 | 수행시간 비율 |
|----------|-------------|
| NONE | 1.00 |
| QUERY HIGH | **0.55** |
| ARCHIVE HIGH | 0.77 |

### ⚠️ HCC DML 주의사항
- **UPDATE**: DELETE + INSERT 방식 → Row Migration 발생
  - 압축 유형이 HCC → Block Compression으로 **다운그레이드**
  - CU 단위 Lock 발생
  - 일반 테이블 대비 **3배 이상** 느림
- **DELETE**: CU 압축 해제 → 삭제 → 재압축 과정
  - 파티션 테이블에서 **DROP PARTITION**으로 대체 권장
- **Parallel UPDATE/DELETE**: 전체 테이블 Lock

### 대용량 HCC 압축 방법
1. **과거 파티션 (INDEX 없음)**: `ALTER TABLE ... MOVE PARTITION ... COMPRESS FOR QUERY HIGH`
2. **과거 파티션 (INDEX 있음)**: CTAS로 중간 테이블 생성 → EXCHANGE PARTITION
3. **동시 INSERT**: LIST+RANGE 복합 파티션 + `PARTITION FOR` 절 + `/*+ APPEND */`

### 압축 유형 확인
```sql
SELECT DBMS_COMPRESSION.GET_COMPRESSION_TYPE('APP_USER', 'TABLE_NAME', ROWID) FROM table;
-- 1: NO COMPRESSION, 2: OLTP, 4: HCC QUERY HIGH, 8: QUERY LOW
-- 16: ARCHIVE HIGH, 32: ARCHIVE LOW, 64: BLOCK
```

### HCC 핵심 정리
- ✅ 읽기 중심(Read-Mostly) 워크로드에 최적
- ✅ 파티셔닝 테이블 필수
- ❌ 빈번한 UPDATE/DELETE 테이블에 부적합
- ❌ 한 테이블에 여러 압축 유형 혼합 지양

---

## Section 05. Smart Flash Cache

### ESFC (Exadata Smart Flash Cache) 개요
- Storage Server의 **고성능 Flash PCIe 카드**에 핫 데이터 캐싱
- X2 버전부터 OLTP INDEX SCAN 향상 목적으로 도입
- INDEX SCAN, FULL TABLE SCAN, Smart Scan 모두 성능 향상

### 캐싱 정책

| 정책 | 설명 |
|------|------|
| **DEFAULT** | 모든 데이터 캐싱 대상 (기본값) |
| **KEEP** | 특정 객체 항상 캐싱 (최대 80%), 다른 객체에 의해 밀려나지 않음 |
| **NONE** | 캐싱 안 함 |

```sql
-- KEEP 모드 테이블 생성
CREATE TABLE t1 (...) STORAGE (CELL_FLASH_CACHE KEEP);

-- INDEX에 KEEP 적용
CREATE INDEX ix1 ON t1(col) STORAGE (CELL_FLASH_CACHE KEEP);
```

### 쓰기 모드

| 모드 | 동작 | 기본값 |
|------|------|--------|
| **Write-Through** | 디스크 먼저 → Flash 캐싱 | ✅ (기본) |
| **Write-Back** | Flash 먼저 → 백그라운드로 디스크 | ❌ (비활성) |

- Write-Back 활성화: `ALTER CELL flashCacheMode=WriteBack;`
- 쓰기 성능 극대화, 단 하드웨어 오류 시 정합성 위험

### 읽기 동작
1. 읽기 I/O 요청 수신
2. Flash Cache와 디스크에 **병렬 읽기** 수행
3. **먼저 읽힌 쪽**의 결과를 DB로 반환
4. Flash에 없으면 메타데이터 기반 캐싱 여부 판단

### Smart Flash Log
- Redo Log 쓰기를 Flash에서 가속화
- Flash Log + 디스크 Redo Log **동시 기록**
- OLTP 트랜잭션 Commit 시간 단축
- 자동 관리, 별도 구성 불필요

### 성능 비교 (INDEX SCAN)
| 테이블/INDEX 속성 | Reads | 수행시간 |
|-------------------|-------|---------|
| NONE / NONE | 15,442 | **30.60초** |
| NONE / KEEP | 15,458 | **3.01초** |
| KEEP / KEEP (HCC) | 19,525 | 6.27초 |

→ INDEX의 CELL_FLASH_CACHE를 KEEP으로 설정하면 **10배** 성능 개선

### ESFC 권장사항
- 기본적으로 **DEFAULT** 사용
- 빈번한 INDEX SCAN 대상 → **KEEP** 고려
- Smart Scan 안 되는 작은 테이블 FULL SCAN → KEEP 고려
- KEEP 설정해도 Smart Scan 시 Flash Cache 활용 → 추가 성능 향상

---

## Section 06. 병렬처리

### 병렬 실행 개요
- 단일 SQL을 **여러 CPU/I/O 자원으로 동시 처리** → 응답 시간 단축
- 주로 DW/DSS, 대규모 배치, INDEX 생성에 활용

### 적용 시기
| 적용 | 비적용 |
|------|--------|
| 대규모 테이블 SCAN/JOIN | 소량 데이터 OLTP |
| INDEX 생성 | INDEX 좁은 범위 조회 |
| 대량 데이터 로딩 | 시스템 자원 포화 상태 |
| 배치 작업 | 동시 다수 사용자 짧은 응답 |

### 병렬 DML
```sql
-- 방법 1: ALTER SESSION
ALTER SESSION ENABLE PARALLEL DML;

-- 방법 2: 힌트 (권장)
INSERT /*+ ENABLE_PARALLEL_DML PARALLEL(4) APPEND */ INTO target
SELECT /*+ PARALLEL(4) */ * FROM source;

DELETE /*+ ENABLE_PARALLEL_DML PARALLEL(4) */ FROM t1 WHERE ...;
UPDATE /*+ ENABLE_PARALLEL_DML PARALLEL(4) */ t1 SET ... WHERE ...;
```
- ⚠️ `ENABLE_PARALLEL_DML` 없으면 DML은 **Serial로 처리됨**
- 실행계획에서 PX COORDINATOR 위치로 확인 가능

### 작동 원리
- **QC (Query Coordinator)**: 병렬 실행 조정
- **PX Server**: 작업 일부를 동시 수행
- **Producer/Consumer 모델**: 생산자 → 소비자로 데이터 전달
- **DOP (Degree of Parallelism)**: PX 서버 세트 내 서버 수
- 테이블 SCAN + 정렬 각각 DOP → 총 **2 × DOP** PX 서버 사용 가능

### Granule (작업 단위)
| 종류 | 실행계획 표시 | 특징 |
|------|-------------|------|
| **Block 기반** | PX BLOCK ITERATOR | 유연한 분배 |
| **파티션 기반** | PX PARTITION RANGE | 파티션 수에 제한, 파티션 수 ≥ 3×DOP 권장 |

### 데이터 분배 방법 (Distribution Methods)

| 방식 | 설명 | 권장 상황 |
|------|------|----------|
| **BROADCAST** | 작은 테이블을 모든 PX에 복제 | 소량 + 대량 JOIN |
| **HASH** | 해시로 균등 분배 | 양쪽 대량 JOIN |
| **PARTITION** | 파티션 단위 할당 | 동일 파티션 구조 JOIN |
| **NONE** | 재분배 없음 | 현재 위치 유지 |

```sql
/*+ PQ_DISTRIBUTE(inner_table, OUTER분배, INNER분배) */
```

#### BROADCAST, NONE (소량 + 대량)
```sql
SELECT /*+ PARALLEL(4) LEADING(A B) USE_HASH(B)
  PQ_DISTRIBUTE(B BROADCAST NONE) */
  A.col, COUNT(*)
FROM small_table A, large_table B
WHERE A.key = B.key GROUP BY A.col;
```
- 선행(소량)이 BROADCAST → PX 수만큼 복제
- ⚠️ **대량 테이블이 BROADCAST되면 심각한 성능 저하** (건수 × DOP 복제)
- JOIN FILTER 생성 시 Cell Offload 극대화

#### HASH, HASH (양쪽 대량)
```sql
/*+ PQ_DISTRIBUTE(B HASH HASH) */
```
- **HASH JOIN BUFFERED** 발생 가능 → TEMP TABLESPACE Write 부하
- 빌드 테이블 건수 많으면 PGA Overflow → Disk Swapping
- BROADCAST 방식이 더 나을 수 있음

#### PARTITION, NONE (동일 파티션 구조)
```sql
/*+ PQ_DISTRIBUTE(B PARTITION NONE) */
```
- **파티션 와이즈 JOIN** → 각 파티션 단위로 JOIN
- PGA Overflow 없음 (월 단위 ~20만 건씩 처리)
- **동일 파티션 구조 대용량 JOIN에 최적**

### 병렬 처리 핵심 정리
- HASH HASH → HASH JOIN BUFFERED 발생 주의
- 동일 파티션 구조 → PARTITION 분배 최적
- 소량+대량 → BROADCAST (단, 방향 주의!)
- Smart Scan을 위해 병렬처리 필요한 경우 多 (Direct Path Read 유도)

---

## Section 07. 개발 시 고려사항

### 일반 DB vs Exadata 비교

| 항목 | 표준 Oracle DB | Oracle Exadata |
|------|---------------|----------------|
| SCAN 방식 | INDEX Random Single Block I/O | **Full Scan + Smart Scan** |
| INDEX | Access Path별 최적 설계 | Smart Scan 고려 최소 INDEX |
| 대용량 처리 | 느림 | Smart Scan으로 **고속 처리** |
| 압축 | Basic만 | **HCC** 지원 |
| 캐시 | 없음 | **ESFC** (Flash Cache) |
| 병렬처리 | 특정 경우만 | Smart Scan 위해 **자주 사용** |

### 8대 개발 원칙

1. **Smart Scan 적극 활용**
   - FULL TABLE SCAN + Direct Path Read 형태 사용
   - `SELECT *` 지양 → 필요 컬럼만

2. **파티셔닝 필수**
   - Partition Pruning으로 SCAN 범위 최소화
   - 50GB Smart Scan < 10GB Smart Scan (I/O 부하 차이)

3. **HCC 압축 활용**
   - 읽기 중심 / 잘 변경 안 되는 데이터에 적용
   - UPDATE 빈번한 OLTP → OLTP 압축 or 비압축

4. **INDEX 최소화**
   - INDEX = Smart Scan 불가
   - 매우 높은 실행 수 + 좁은 범위 → INDEX
   - 낮은 실행 수 + 좁은 범위 → Smart Scan 고려

5. **ESFC 활용**
   - DEFAULT 기본, 중요 객체는 KEEP

6. **행 단위 처리 지양**
   - PL/SQL 루프, 스칼라 서브쿼리, 사용자 정의 함수 ❌
   - NESTED LOOP JOIN → **HASH JOIN** 전환 고려
   - **집합 기반 SQL (Set-Based SQL)** 작성

7. **병렬 쿼리 최적화**
   - Serial에서 Direct Path Read 안 되면 → 병렬 사용
   - 과도한 병렬 → 리소스 경합 주의

8. **OLTP 워크로드 주의**
   - HCC 테이블에 쓰기 집약 ❌
   - HCC Lock = CU Level (Row Level 아님!)
   - HCC INDEX SCAN = CU 단위 I/O + 압축 해제 CPU 오버헤드
