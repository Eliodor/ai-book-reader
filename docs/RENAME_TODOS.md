# Rename / rebrand TODOs

Эти места **не блокируют сборку**, но содержат отсылки к оригинальному Anx Reader. Адресовать перед публичным релизом или когда займётесь конкретной фичей.

## URLs к `anx.anxcye.com` (домен Anx Reader)

Указывают на сайт оригинального Anx Reader. Замените на свой домен/репозиторий или закомментируйте функциональность, пока её нет.

### Документация и страницы
| Файл | URL |
|---|---|
| `lib/page/iap_page.dart:140` | `https://anx.anxcye.com/privacy.html` |
| `lib/page/iap_page.dart:149` | `https://anx.anxcye.com/terms.html` |
| `lib/widgets/settings/about.dart:172` | `https://anx.anxcye.com/privacy` |
| `lib/widgets/settings/about.dart:181` | `https://anx.anxcye.com/terms` |
| `lib/widgets/settings/about.dart:190` | `https://anx.anxcye.com/docs` |
| `lib/page/settings_page/sync.dart:68` | `https://anx.anxcye.com/docs/sync/webdav` |
| `lib/service/translate/deepl.dart:122` | `https://anx.anxcye.com/docs/translate/deepl` |
| `lib/service/translate/google_api.dart:94` | `https://anx.anxcye.com/docs/translate/google` |
| `lib/service/translate/microsoft_api.dart:97` | `https://anx.anxcye.com/docs/translate/azure` |
| `lib/service/tts/aliyun/aliyun_tts_backend.dart:51` | `https://anx.anxcye.com/docs/tts/aliyun` |
| `lib/service/tts/azure_tts_backend.dart:36` | `https://anx.anxcye.com/docs/tts/azure` |
| `lib/service/tts/openai_tts_backend.dart:40` | `https://anx.anxcye.com/docs/tts/openai` |

### Функциональные эндпоинты (важнее — влияют на runtime)
| Файл | URL | Что делает |
|---|---|---|
| `lib/utils/check_update.dart:29` | `https://api.anx.anxcye.com/api/info/latest` | Проверка обновлений приложения. **Будет вести к Anx-обновлениям, а не к нашим.** Отключить или сменить на свой эндпоинт/GitHub releases. |
| `lib/utils/check_update.dart:95` | `https://anx.anxcye.com/download` | Кнопка "Скачать" в диалоге обновления. |
| `lib/providers/fonts.dart:16` | `https://fonts.anxcye.com/` (`fontBaseUrl`) | CDN со шрифтами. Anx раздаёт шрифты со своего сервера. Либо хостить свои, либо заменить на public Google Fonts API, либо отключить шрифт-фичу. |
| `lib/page/settings_page/subpage/fonts.dart:40` | `https://fonts.anxcye.com/${font.preview}` | То же CDN, для preview-картинок. |

## Миграционные пути (legacy data import)

`lib/dao/database.dart:333-337` и `lib/utils/get_path/macos_migration.dart` содержат код, который ищет старые пути установки Anx Reader (`/data/user/0/com.anxcye.anx_reader/...` и аналог macOS) и переносит данные. Для пользователей нашего форка эти пути недоступны (Android sandbox), миграция — no-op. Не сломано, но мёртвый код.

**Опции:**
- Оставить как есть (мертво, безвредно).
- Удалить миграционную логику целиком — упростит код.

## Apple Developer Team ID

`macos/fastlane/Fastfile:72` содержит `teamID: "28W956D5K8"` — это ID команды разработчиков Anx. Ваша Apple-сборка не будет работать с этим ID. Замените на свой когда у вас будет Apple Developer account.

## Inno Setup GUID (Windows installer)

`scripts/compile_windows_setup-inno.iss` — `MyAppId` использует GUID `{32610E5D-B613-420A-B68F-A57E2102BCE3}`. Этот GUID идентифицирует приложение для Windows Installer; если кто-то поставит наш форк на ту же машину, где стоит оригинальный Anx — установщик их перепутает. **Сгенерировать новый GUID** через `uuidgen` или Inno Setup IDE → Tools | Generate GUID, заменить.

## Прочие места

- В коде встречаются комментарии и идентификаторы, упоминающие Anx по сути работы — оставить, т.к. это чужой исторический контекст; постепенно переписывать по мере правок.
- Иконки приложения (`assets/icon/`, `android/app/src/main/res/mipmap-*/`, `ios/Runner/Assets.xcassets/AppIcon.appiconset/`, `macos/Runner/Assets.xcassets/AppIcon.appiconset/`, `windows/runner/resources/app_icon.ico`, `web/icons/`) **остались от Anx Reader.** Для своего бренда сгенерировать через `flutter_launcher_icons` или вручную.
- `assets/CHANGELOG.md` — копия чейнджлога Anx, актуальна для них, не для нас.
- `LICENSE` — оставить как есть (MIT с копирайтом Anxcye); это требование MIT-лицензии при форке.
