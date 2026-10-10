# Data handling

Voxline does not operate an account service or a subtitle backend. Processing uses the local device and services explicitly configured in the application.

| Operation | Data destination |
| --- | --- |
| Local WhisperKit transcription | Audio is processed on device; models are downloaded separately |
| Apple Translation | Installed language resources process subtitle text on device |
| Cloud transcription | Audio is sent to the configured provider endpoint |
| API translation | Subtitle text, nearby context, and translation instructions are sent to the configured endpoint |
| Optional iCloud sync | Tasks and subtitles use the selected iCloud Drive folder; source media is copied only when enabled |

API credentials stay in the device Keychain and are excluded from task documents. Sharing a task can disclose subtitles, media metadata, configured service URLs, and translation instructions.

The device stores tasks, models, media access records, processing audio, and diagnostic evidence. Evidence can contain recognized text and raw provider responses. Exported subtitles and videos use the platform's file and sharing interfaces.

Provider retention and billing are controlled by the provider; iCloud storage is controlled by the selected Apple account and folder. Review these services before sending private media. Bug reports should use synthetic or redistributable samples and omit credentials, private transcripts, and diagnostic caches.
