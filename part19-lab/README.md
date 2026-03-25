# Part 19 실습 - 튜닝 실무 사례 16선

## 실행 방법

```bash
ssh oracle@192.168.50.21
source ~/.bash_profile
sqlplus / as sysdba

-- 1. 공통 데이터 세트 생성 (최초 1회, 약 10~15분)
@/root/.openclaw/workspace/oracle-sql-tuning-compass/part19-lab/setup_data.sql

-- 2. 사례별 실습 (순서 자유)
@/root/.openclaw/workspace/oracle-sql-tuning-compass/part19-lab/case_01.sql

-- 3. 실습 종료 후 정리
@/root/.openclaw/workspace/oracle-sql-tuning-compass/part19-lab/cleanup.sql
```

## 데이터 세트

| 테이블 | 건수 | 설명 |
|--------|------|------|
| T_CUSTOMER | 10만 | 고객 (VIP 5%) |
| T_ORDER | 100만 | 주문 헤더 |
| T_ORDER_DETAIL | 500만 | 주문 상세 |
| T_PRODUCT | 5만 | 상품 |
| T_CATEGORY | 50 | 카테고리 (PREMIUM 10%) |
| T_CODE | 200 | 공통코드 |
| T_STORE | 1,000 | 매장 |
| T_LOG | 200만 | 시스템로그 |
| T_BOARD | 50만 | 게시판 |
| T_DEPT | 100 | 부서 |
| T_STATUS | 20 | 상태코드 |
| T_DAILY_SALES | 300만 | 일별매출 |

## 사례 ↔ 튜닝 기법 매핑

| # | 사례 | 핵심 기법 | 패턴 |
|---|------|----------|------|
| 01 | INDEX SKIP SCAN 활용 | 선두 컬럼 없이 INDEX 활용 | 🔵 INDEX |
| 02 | 적절한 INDEX 선택 | 올바른 INDEX 힌트 지정 | 🔵 INDEX |
| 03 | NL → HASH JOIN 변경 | 대량 데이터 JOIN 방식 변경 | 🟢 JOIN |
| 04 | JPPD 활용 | JOIN PREDICATE PUSH DOWN | 🟢 JOIN |
| 05 | JOIN → 스칼라 서브쿼리 | 반복 ACCESS 최소화 | 🟡 서브쿼리 |
| 06 | EXISTS + JOIN 순서 변경 | 필터링 순서 최적화 | 🟡 서브쿼리 |
| 07 | UNION ALL 실행 계획 분리 | 조건별 최적 경로 분리 | 🔴 실행계획 분리 |
| 08 | JOIN 순서 + 스칼라 서브쿼리 | 복합 기법 적용 | 🟢 JOIN + 🟡 서브쿼리 |
| 09 | JPPD + NL JOIN | 인라인뷰 침투로 PGA 절감 | 🟢 JOIN |
| 10 | WINDOW 함수 + EXISTS | 분석함수로 반복 ACCESS 제거 | 🟡 서브쿼리 |
| 11 | UNION → CASE WHEN 통합 | 동일 테이블 반복 SCAN 제거 | 🔴 실행계획 분리 |
| 12 | INDEX FULL SCAN(MIN/MAX) | 정렬 없이 최소/최대값 | 🔵 INDEX |
| 13 | 페이징 후 JOIN + 스칼라 | 소량 추출 후 JOIN | ⚪ 페이징 |
| 14 | JOIN 순서/방법 최적화 | 불필요 필터링 제거 | 🟢 JOIN |
| 15 | JPPD로 GROUP BY 제거 | 인라인뷰 침투로 집계 제거 | 🟢 JOIN |
| 16 | JOIN + 서브쿼리 종합 | 복합 최적화 | 🟢 JOIN + 🟡 서브쿼리 |

## 패턴별 그룹

| 패턴 | 사례 | 핵심 원리 |
|------|------|----------|
| 🔵 **INDEX** | 01, 02, 12 | 올바른 인덱스 선택/활용 |
| 🟢 **JOIN** | 03, 04, 08, 09, 14, 15 | JOIN 방식/순서/JPPD |
| 🟡 **서브쿼리** | 05, 06, 10, 16 | 스칼라 서브쿼리, EXISTS |
| 🔴 **실행계획 분리** | 07, 11 | UNION ALL, CASE WHEN |
| ⚪ **페이징** | 13 | 페이징 후 JOIN |

## 추천 학습 순서

**1단계 - 기본** (INDEX + JOIN 기초)
```
case_01 → case_02 → case_03 → case_12
```

**2단계 - 서브쿼리/실행계획** 
```
case_05 → case_06 → case_07 → case_11
```

**3단계 - 고급** (JPPD + 복합 기법)
```
case_04 → case_09 → case_15 → case_08 → case_10
```

**4단계 - 종합**
```
case_13 → case_14 → case_16
```

## 보조 자료

- `pattern_summary.md` — 패턴별 핵심 원리/적용 조건 정리
- `quiz.md` — 18문제 퀴즈 (기본~고급)
