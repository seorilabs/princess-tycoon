# Princess Tycoon 프로젝트 지침

- 공통 지침은 상위 사용자 `AGENTS.md`를 따른다.
- 구현 정본은 `docs/10_현대형_무한성장_GDD.md`와 `docs/11_현대형_구현계약.md`다.
- `docs/00~09`와 `extract/`는 원작 분석 레퍼런스이며 충돌 시 현대형 정본이 우선한다.
- 원작 추출 이미지·텍스트·음악·폰트를 런타임 빌드에 포함하지 않는다.
- 게임 프로젝트는 `godot/`에 둬 `extract/`가 Godot import 대상이 되지 않게 한다.
- 게임 규칙은 `godot/src/core/`, 화면과 렌더링은 `godot/src/ui/`, 수치는 `godot/data/`로 분리한다.
- 무작위 처리는 저장된 seed/rngCounter 기반이어야 하며 시스템 시각을 직접 난수로 쓰지 않는다.
- Godot headless exit code만 신뢰하지 말고 로그의 `SCRIPT ERROR`, `ERROR:`, missing resource를 검사한다.
- 한국어 UI는 번들된 OFL 폰트를 사용한다.

