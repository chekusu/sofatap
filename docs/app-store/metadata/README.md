# Sofatap App Store metadata

This is the canonical `asc metadata` directory for Sofatap iPhone/iPad. English (U.S.) is the primary locale.

- `version/1.0/` is the metadata live with 1.0 (build 23), approved and released on October 31, 2026. Keep it as the record of that release.
- `version/1.0.2/` (November 8, 2026) adds the long-press shortcut panel from #29 to What's New and updates the gesture sentence in every description: in the default preset a long press now opens the shortcut panel and drag is tap then hold. Other fields match the live 1.0.1. Screenshots and the App Preview for 1.0.2 were rebuilt from device captures and uploaded separately.
- `version/1.0.1/` is staged for the next version (November 1, 2026). It carries the App Store keyword update, the pointer speed setting from #12 and the TV navigation changes on main. `app-info/` now holds the 1.0.1 names and subtitles.

Since 1.0.1 the public name is **Sofatap** plus a short descriptor (for example "Sofatap: Remote for PC & TV"), so the name carries searchable category words. The app's on-device display name stays Sofatap. 1.0.1 adds two locales, **en-GB** and **es-MX**. English (U.K.) is the default store language in India, Indonesia and Saudi Arabia and an indexed second language in many other storefronts. Spanish (Mexico) serves Latin America. Sofatap is not distributed in the EU, so es-ES, de-DE and fr-FR reach few storefronts. Apple's [storefront language table](https://developer.apple.com/help/app-store-connect/reference/app-store-localizations) lists which locales each storefront uses.

The 1.0.1 marketing and support URLs are https://sofatap.app/ and https://sofatap.app/support/, the same as the live 1.0 listing. The `version/1.0/` files still hold the earlier GitHub URLs that were staged before the website routes were live.

Metadata rules for these files: no other mobile platform names (Android, Google TV) per guideline 2.3.10; no third-party trademarks or app names such as Steam in keywords; label smart TV control as beta until TV hardware acceptance is recorded; do not repeat name/subtitle words in the keyword field.

Field timing: promotional text can be edited on a live version without review. Name, subtitle, keywords, description, What's New and new locales apply only through a new version that passes review.

The 1.0.1 build also contains the #12 computer volume control, but the metadata does not advertise it: no public desktop receiver supports it yet, and reviewers use receiver 0.8.1 beta.1. Add it to the store copy in the version after a receiver with volume support is published (Bruce's decision, November 1, 2026).

| App/site language | App Store locale |
| --- | --- |
| English | en-US |
| Simplified Chinese | zh-Hans |
| Japanese | ja |
| Spanish | es-ES |
| French | fr-FR |
| German | de-DE |
| Brazilian Portuguese | pt-BR |
| Korean | ko |
| Arabic | ar-SA |
| Hindi | hi |
| Russian | ru |
| Indonesian | id |
| English (U.K.), store only | en-GB |
| Spanish (Mexico), store only | es-MX |

The JSON files contain app name, subtitle, privacy URL, description, keywords, promotional text, support URL and marketing URL. The 1.0 files omit `whatsNew` for the initial release; the 1.0.1 files include it. They contain no review contact, pricing, territory, release-mode or legal-agreement changes. Translation lengths and field formats have been checked; independent native-language editorial review remains pending. The 1.0.1 names, keywords and new paragraphs outside English, Chinese and Japanese are machine-drafted and should get a native-speaker pass.

The 1.0 text describes manual desktop controls and explains conditional live editing, on-device dictation, computer requirements and experimental TV adapters. Build 23 adds hold-to-drag tolerance to build 22 and includes customizable gesture presets; it does not include the unreleased desktop volume or pointer-speed changes on main. Descriptions now mention iPhone/iPad support, remove the obsolete build-15 double-tap mapping and link desktop receiver 0.8.1 beta.1. They do not advertise autonomous AI operation, universal TV mouse support or lock-screen unlocking. [Build-23 review notes](../app-store-1.0-23-review-notes.txt) give reviewers the matching pairing and gesture path. The [build-15 notes](../app-store-1.0-15-review-notes.txt) remain as historical evidence.

Screenshots and previews are managed separately. Apple can inherit primary-language images when a localization is added; inherited English images are not localized images. Earlier media used actual build-15 device captures. Inspect retained media against build 23, including the old guide's embedded gesture labels, and provide the required iPad screenshot coverage before submitting the universal build. Do not represent a retained build-15 capture as a new build-23 capture. [Apple localization guidance](https://developer.apple.com/help/app-store-connect/manage-app-information/localize-app-information).


## Release through GitHub Actions (1.0.1 and later)

The [iOS App Store release workflow](../../../.github/workflows/ios-app-store.yml) is run by hand from the Actions tab. It reads the version from `ios/project.yml`, archives with cloud-managed signing on a GitHub macOS runner, and uses [`scripts/app_store_release.py`](../../../scripts/app_store_release.py) for App Store Connect. It needs four repository secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (an Admin-role team API key) and `APPLE_TEAM_ID`.

| Mode | What it does |
| --- | --- |
| `check` | Build and export the IPA as an artifact; print a read-only metadata plan. Changes nothing in App Store Connect. |
| `upload` | Also upload the build, create the version if needed, write `app-info/` and `version/<version>/` localizations, and attach the build once it is processed. |
| `submit` | Also set the reviewer notes (contact details are copied from the previous version) and submit for App Review. |

The script never deletes locales or files. Screenshots are not managed here; new locales fall back to the primary-language screenshots.

## Validate and inspect a draft update

Run from the repository root:

```sh
asc metadata validate --dir docs/app-store/metadata --output json
asc metadata push --app 6822188472 \
  --app-info af1c12f1-7b11-4518-9644-c7fc92174fed \
  --version 1.0.1 --platform IOS \
  --dir docs/app-store/metadata --dry-run --output json
```

The app-info ID must be the editable record for the version being prepared. `fedc6f5f-1afd-4162-8160-c0100ba98632` is the record that went live with 1.0 and is locked; `af1c12f1-7b11-4518-9644-c7fc92174fed` was created with 1.0.1 (November 2, 2026). After 1.0.1 goes live, look up the next editable record with the app-info list before pushing.

Review the differences, then omit `--dry-run` to save the draft. Do not add `--allow-deletes`. These files do not change screenshots, privacy questionnaire publication, price, availability or release type. Read back the saved metadata and run `asc validate` afterward.

During the October 14 staging run, this CLI's metadata lookup omitted version locales that a paginated localization list returned. If a plan proposes creating an existing locale, use `asc localizations list --version VERSION_ID --paginate` and update the existing locale with `asc localizations update --version VERSION_ID --locale LOCALE` and the intended fields. Verify all 12 locales through the paginated API result; do not delete or recreate them to make a plan pass.

## Build and review details

Build 23 is `90004eb6-6cdd-42e4-9475-9eecd34d02a6`, from exact release source `c7ad3ab2cb5f86c55839ff349c9026561ec8b68d`. Main also carries build number 23 but contains additional unreleased changes; use the already uploaded build instead of treating a fresh main build as the same package. The existing version is `91096e3e-ef6c-4da6-8e3d-64e22c760a25`. Read its current review state before changing its build; an active review must be withdrawn through the authorized release workflow first.

```sh
asc versions attach-build \
  --version-id 91096e3e-ef6c-4da6-8e3d-64e22c760a25 \
  --build 90004eb6-6cdd-42e4-9475-9eecd34d02a6 --output json
```

The approved review contact is maintained privately, outside the repository. Copy the existing approved Sofatap TestFlight contact into the formal App Store review detail; do not invent or publish contact values. `asc review details-update` accepts `--contact-first-name`, `--contact-last-name`, `--contact-email`, `--contact-phone`, `--demo-account-required=false` and `--notes`. It does not offer a notes-file option. Use a subprocess argument list to read the notes file and private contact JSON without shell interpolation or logging those values.

Saving these drafts and attaching a build do not submit the app for review. Do not run a submit command as part of metadata preparation. The [build-15 readiness audit](../readiness-1.0-15.md) is historical; rerun validation and verify current media, privacy and reviewer access for build 23 before the separately authorized submission.
