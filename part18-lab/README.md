# Part 18 실습 - Oracle 성능분석 기본방법론

## 실습 순서

| # | 파일 | 주제 | 소요 |
|---|------|------|------|
| 00 | `00_env_check.sql` | 환경 점검 (DB, AWR, SGA) | 5분 |
| 01 | `01_time_model.sql` | 시간 모델 (DB_TIME = DB_CPU + Wait) | 10분 |
| 02 | `02_sysstat.sql` | 시스템 통계 (Buffer Hit, Soft Parse) | 10분 |
| 03 | `03_wait_event.sql` | WAIT EVENT 분석 | 15분 |
| 04 | `04_cpu_osstat.sql` | CPU 사용률 분석 | 10분 |
| 05 | `05_top_sql.sql` | TOP SQL 분석 | 10분 |
| 06 | `06_ash.sql` | ASH (Active Session History) | 10분 |
| 07 | `07_awr_report.sql` | AWR/ASH/ADDM Report 생성 | 15분 |
| 08 | `08_full_trend.sql` | 통합 성능 Trend 대시보드 | 10분 |
| 09 | `09_load_gen.sql` | 부하 생성 → 전/후 비교 | 15분 |

## 실행 방법

```bash
# RAC 1번 노드 접속
ssh oracle@192.168.50.21
source ~/.bash_profile
sqlplus / as sysdba

-- 실습 파일 실행
@/root/.openclaw/workspace/oracle-sql-tuning-compass/part18-lab/00_env_check.sql
```

## 실습 흐름

```
1. 00~06: 개별 성능 뷰 이해 (이론 확인)
2. 08: 통합 Trend로 전체 그림 파악
3. 09: 부하 생성 → 08로 변화 확인 → 03/05/06으로 원인 분석
4. 07: AWR Report로 종합 리포트 생성
```

## 핵심 공식

- `DB_TIME = DB_CPU + Non-Idle Wait Time`
- `Buffer Cache Hit % = (1 - physical reads / session logical reads) * 100`
- `Soft Parse % = (1 - hard parse / total parse) * 100`
- `CPU % = BUSY_TIME / (BUSY_TIME + IDLE_TIME) * 100`
- AWR 뷰는 **누적값** → DELTA 계산 필수

## 목표값

| 지표 | 목표 |
|------|------|
| Buffer Cache Hit | 99%+ |
| Soft Parse | 95%+ |
| log file sync | < 10ms |
| db file sequential read | < 10ms |
| PGA optimal | 99%+ |
