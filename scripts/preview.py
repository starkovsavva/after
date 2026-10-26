"""Explicit demo fixture for checking the native window, isolated from the real library."""
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
directory = root / "meetings" / "demo-product"
directory.mkdir(parents=True, exist_ok=True)

def save(name, data):
    (directory / name).write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

save("meta.json", {"id": "demo-product", "title": "Запуск пилота", "createdAt": time.time(),
     "source": "source.mp3", "status": "ready", "duration": 1840, "speakerNames": {"speaker_1": "Анна", "speaker_2": "Майкл"},
     "completedTasks": [], "focus": "Решения, сроки, бюджет и полезные английские выражения.", "recordingTracks": False, "hasVideo": False})
save("transcript.json", {"duration": 1840, "warnings": [], "model": "demo", "segments": [
    {"id": 0, "start": 65, "end": 78, "speaker": "speaker_1", "text": "Давайте начнём с пилота на 25 участников. Бюджет на первый месяц — 80 тысяч рублей, превышать его пока не будем.", "overlap": False},
    {"id": 1, "start": 190, "end": 201, "speaker": "speaker_2", "text": "Let's circle back to the onboarding flow on Friday. I can put together a first draft before then.", "overlap": False},
    {"id": 2, "start": 403, "end": 415, "speaker": "speaker_1", "text": "Для пилота пока не решено, какие метрики удержания считать. Обсудим это отдельно.", "overlap": False}
]})
save("summary.json", {"overview": "Команда договорилась начать с небольшого пилота и вернуться к сценарию онбординга в пятницу. Бюджет первого месяца ограничен 80 тысячами рублей. Метрики удержания ещё предстоит согласовать.",
     "overviewClaims": [
         {"text": "Команда договорилась начать с небольшого пилота и вернуться к сценарию онбординга в пятницу.", "itemIndices": [0, 1]},
         {"text": "Бюджет первого месяца ограничен 80 тысячами рублей.", "itemIndices": [2]},
         {"text": "Метрики удержания ещё предстоит согласовать.", "itemIndices": [3]}
     ],
     "provider": "local", "model": "demo", "generatedAt": time.time(), "warnings": [], "items": [
         {"kind": "decision", "text": "Начать с пилота на 25 участников.", "owner": "", "due": "", "segmentIDs": [0]},
         {"kind": "action", "text": "Подготовить первый черновик сценария онбординга.", "owner": "Майкл", "due": "до пятницы", "segmentIDs": [1]},
         {"kind": "detail", "text": "Бюджет на первый месяц — не более 80 000 ₽.", "owner": "", "due": "", "segmentIDs": [0]},
         {"kind": "question", "text": "Какие метрики удержания использовать в пилоте?", "owner": "", "due": "", "segmentIDs": [2]}
     ], "cards": [
         {"id": "demo-circle-back", "kind": "phrase", "front": "circle back", "back": "Вернуться к вопросу позже, чтобы продолжить обсуждение.",
          "context": "Let's circle back to the onboarding flow on Friday.", "segmentIDs": [1]},
         {"id": "demo-put-together", "kind": "phrase", "front": "put together a first draft", "back": "Подготовить первый черновик.",
          "context": "I can put together a first draft before then.", "segmentIDs": [1]}
     ]})
save("examples.json", {"demo-circle-back": {"example": "Can we circle back to the budget after we review the timeline?",
     "translation": "Можем вернуться к бюджету после того, как обсудим сроки?", "explanation": "Circle back to something — вернуться к уже затронутой теме. Удобная фраза для рабочих встреч."}})
(root / "settings.json").write_text(json.dumps({"mode": "local", "localModel": "qwen3.5:9b-q4_K_M", "cloudModel": "gpt-4.1-mini",
    "language": "ru", "diarization": True, "speakerCount": 0, "autoSummary": True,
    "focus": "Решения, задачи, сроки и важные детали."}, ensure_ascii=False), encoding="utf-8")
# A second, explicitly invented meeting exercises search across the whole library.
directory = root / "meetings" / "demo-access"
directory.mkdir(parents=True, exist_ok=True)
save("meta.json", {"id": "demo-access", "title": "Доступы к стенду", "createdAt": time.time() - 86400,
     "source": "source.mp3", "status": "ready", "duration": 620, "speakerNames": {"speaker_1": "Алекс"},
     "completedTasks": [], "focus": "Доступы и сроки.", "recordingTracks": False, "hasVideo": False})
save("transcript.json", {"duration": 620, "warnings": [], "model": "demo", "segments": [
    {"id": 0, "start": 0, "end": 11, "speaker": "speaker_1", "text": "Выдадим временный доступ к тестовому стенду до четверга. Доступ к персональным данным для пилота не нужен.", "overlap": False},
    {"id": 1, "start": 75, "end": 90, "speaker": "speaker_1", "text": "Please follow up with the team before the pilot starts.", "overlap": False}
]})
save("summary.json", {"overview": "Для пилота выдадут временный доступ к тестовому стенду до четверга. Персональные данные в пилоте не потребуются.",
     "overviewClaims": [
         {"text": "Для пилота выдадут временный доступ к тестовому стенду до четверга.", "itemIndices": [0]},
         {"text": "Персональные данные в пилоте не потребуются.", "itemIndices": [1]}
     ], "provider": "local", "model": "demo", "generatedAt": time.time(), "warnings": [], "items": [
         {"kind": "action", "text": "Выдать временный доступ к тестовому стенду.", "owner": "", "due": "до четверга", "segmentIDs": [0]},
         {"kind": "detail", "text": "Для пилота не требуется доступ к персональным данным.", "owner": "", "due": "", "segmentIDs": [0]}
     ], "cards": [
         {"id": "demo-follow-up", "kind": "phrase", "front": "follow up with the team", "back": "Связаться с командой повторно и уточнить результат.",
          "context": "Please follow up with the team before the pilot starts.", "segmentIDs": [1]}
     ]})
print(root)
