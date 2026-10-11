// Legal document texts for in-app reader modals.

abstract final class LegalDocuments {
  static const privacyPolicy = '''
Privacy Policy — Metadata Editor

Effective Date: October 10, 2026
Application: Metadata Editor (iOS)
Publisher: vxti
Developer: vxti
Contact: vxti.dev@gmail.com
Platform Directory: Zlarp (https://zlarp.com)

1. Overview & Core Privacy Commitment
Metadata Editor is engineered from the ground up on a local-first, privacy-by-design architecture. The application provides professional-grade on-device metadata inspection, editing, and stripping for image and video media.

We believe your personal media, EXIF records, capture timestamps, camera serial numbers, and geographic location coordinates belong exclusively to you.

• Zero Cloud Processing: All metadata operations run 100% locally on your iOS device via our compiled Swift media engine (ProbeCore).
• Zero Automated Telemetry: Metadata Editor does not contain any analytics SDKs, advertising frameworks, crash-reporting daemons, user tracking identifiers (IDFA), or telemetry beacons.
• Zero Third-Party Data Sharing: We do not sell, rent, monetize, or transmit your media or personal data to any third party.

2. Information We Access and Process
Metadata Editor only interacts with files and information that you explicitly choose to import into the application.

A. Media Files & Embedded Metadata
When you select an image or video file using the system document picker (UIDocumentPickerViewController) or file sharing interface:
• Formats Processed: JPEG, PNG, HEIC, MP4, and MOV files.
• Metadata Fields Read & Modified: EXIF, TIFF, GPS, IPTC, XMP tags, and QuickTime container atoms (including camera make, model, lens profile, focal length, aperture, ISO, shutter speed, capture date/time, and GPS coordinates).
• Processing Location: All parsing, rewriting, and cryptographic checksum validations occur entirely in-memory and in local sandboxed storage within your iOS device. Your media is never uploaded to external servers or cloud endpoints.

B. Device & Photo Library Permissions
• Files & Storage Access: Metadata Editor requests access to the individual files or folders you explicitly select through the standard iOS document picker.
• Apple Photos Access: When you choose Photos import, the app requests iOS Photos read/write authorization on demand and supports both full and limited library access. The app reads the selected original resource to make a sandboxed working copy; it does not modify the source Photos asset. iCloud Photos may download a cloud-backed original when selected.
• Camera & Microphone: Metadata Editor does not access your physical device camera or microphone.

C. Saved Presets & Local Settings
• When you create custom camera recipes, randomization profiles, or saved presets, these configurations are stored locally in the application's private sandboxed SharedPreferences / Application Support directory.
• Preset configurations are never synced to any remote database.

3. Data Storage, Retention, and Deletion
A. Local Sandbox Storage
• Files imported into the application and new files generated during processing are stored locally in the application's sandboxed Processed Media directory (Documents/Processed Media/).
• Because iOS file sharing is enabled (UIFileSharingEnabled), you can directly inspect, copy, or delete these files at any time using the native Apple Files app.

B. Source File Immutability
• Metadata Editor enforces a strict architectural rule: source files are immutable. The application never alters or overwrites your original imported files in-place. All operations write output to newly created files.

C. Data Deletion
• Session Removal: Tapping "Delete session copy" within the application immediately and permanently deletes the sandboxed working copy from local storage.
• Cache Clearing: The application provides a one-tap cache clearing control in Settings to remove all temporary working files.
• Application Uninstall: Deleting Metadata Editor from your iOS device immediately and permanently purges all sandboxed data, including session copies, temporary files, and saved presets, via the iOS operating system.

4. Network Connections & External Links
A. Network Inactivity
• The application executes no automated network requests, background polling, or API calls during normal operation.
• The app operates fully offline with complete functionality when Airplane Mode is active or when network access is disabled.

B. User-Initiated External Links
• The application contains an explicit link to the showcase website (Visit Website -> https://zlarp.com).
• When tapped, iOS opens the destination URL in your default web browser (Safari). Any browsing activity on external websites is governed by the respective website's privacy terms.

5. Third-Party Libraries & Subprocessors
Metadata Editor incorporates no third-party tracking, analytics, or advertising libraries. The application is built using:
• Flutter SDK: Used solely for rendering the on-device user interface.
• Apple Native Frameworks: ImageIO, CoreMedia, AVFoundation, UniformTypeIdentifiers, and Foundation for bit-level container processing.
There are no third-party data subprocessors.

6. Children's Privacy
Metadata Editor does not knowingly collect, transmit, or solicit personal information from children under the age of 13 (or under 16 in the European Economic Area). Because the application collects zero personal data from any user, it is fully compliant with COPPA and GDPR requirements.

7. Your Rights (GDPR & CCPA/CPRA)
Under global privacy regulations, including the European Union General Data Protection Regulation (GDPR) and California Consumer Privacy Act (CCPA):
• Right to Access / Portability: All your processed media and metadata remain on your device and are fully accessible via the Files app at all times.
• Right to Erasure: You can delete all local data at any time directly through the app or by deleting the app.
• Because we do not collect, transmit, or store personal data on any server, we have no personal data to provide, rectify, or delete upon request.

8. Contact & Legal Publisher
For questions regarding this Privacy Policy:
Developer & Publisher: vxti
Email: vxti.dev@gmail.com
Platform Directory: Zlarp (https://zlarp.com)
''';

  static const termsOfUse = '''
Terms of Use — Metadata Editor

Effective Date: October 10, 2026
Application: Metadata Editor (iOS)
Publisher: vxti
Developer: vxti
Contact: vxti.dev@gmail.com
Platform Directory: Zlarp (https://zlarp.com)

1. Acceptance of Terms
By downloading, installing, accessing, or using Metadata Editor ("the Application"), you agree to be bound by these Terms of Use ("Terms"). If you do not agree to these Terms, do not install or use the Application.

These Terms constitute a binding legal agreement between you ("User" or "you") and vxti ("Developer", "we", "us", or "our"). Third-party distribution directories and platform showcases, including Zlarp (https://zlarp.com), are independent hosting portals and are not parties to this license agreement.

2. License Grant & Permitted Use
A. License
Subject to your compliance with these Terms, vxti grants you a revocable, non-exclusive, non-transferable, limited license to download, install, and use Metadata Editor on Apple iOS devices that you own or control, solely for personal or legitimate commercial workflow purposes.

B. Permitted Application Use
Metadata Editor is designed to provide professional on-device tools for inspecting, editing, stripping, standardizing, and randomizing metadata (EXIF, TIFF, GPS, IPTC, XMP, and QuickTime atoms) in supported media container formats (JPEG, PNG, HEIC, MP4, MOV).

C. Restrictions
You agree that you will not:
• Reverse engineer, decompile, decrypt, disassemble, or attempt to derive the source code of compiled binary components of the Application, except where permitted by applicable law.
• Modify, adapt, translate, or create derivative works of the Application's proprietary native engines without express authorization.
• Use the Application for any unlawful purpose, including attempting to forge evidential digital forensics or infringe third-party copyright or intellectual property rights.
• Distribute, lease, rent, loan, or sublicense the Application to any third party outside authorized Apple distribution channels.

3. User Ownership & Media Responsibility
A. Ownership of Your Media
You retain all copyright, ownership, and intellectual property rights in and to any photos, video recordings, audio tracks, and files that you import into or process with the Application. Neither vxti nor Zlarp claims any ownership, title, or interest in your media.

B. Representation & Warranties Regarding Content
By importing files into the Application, you represent and warrant that:
1. You are the creator and owner of the media, or have acquired all necessary licenses, permissions, and consents to inspect and modify the media and its embedded metadata.
2. Your modification of the metadata does not violate any third-party contractual obligations, privacy rights, trademarks, or copyrights.

4. Metadata Accuracy & Technical Limitations
A. "As-Is" Metadata Writing
Metadata Editor utilizes public Apple APIs and specialized native container parsers to write standards-compliant metadata into supported file formats. However, because metadata interpretation varies widely across operating systems, social media networks, cloud storage providers, and camera manufacturers:
• No Guarantee of Third-Party Display: We do not guarantee that third-party applications, websites, social networks, or photo viewers will display, parse, or preserve all custom or modified metadata fields.
• Platform Ingest Stripping: Many external platforms (including messaging apps and social networks) automatically sanitize or strip EXIF/GPS metadata upon upload as part of their own processing pipelines.

B. Apple Photos & Source Attribution
The Application operates with file-backed storage and public APIs. Apple Photos UI display, search indexing, and attribution behavior are controlled entirely by Apple's proprietary system algorithms. While Metadata Editor provides workflow guidance for importing media into Apple Photos via Files and iCloud, the Developer makes no representation that Apple Photos will interpret or display modified fields identically to native hardware captures.

C. Preserved Media Integrity
Metadata Editor does not re-encode video tracks or compress image bitmaps; it rewrites container metadata headers while preserving media stream integrity. You acknowledge that certain heavily proprietary or non-standard container boxes may be refused by the engine to protect your files from corruption.

5. Third-Party Services & Trademark Disclaimers
• Non-Affiliation: Metadata Editor is developed independently by vxti. The Application is not endorsed by, sponsored by, or affiliated with Apple Inc., Google LLC, Samsung Electronics Co., Ltd., Sony Group Corporation, or any other camera manufacturer referenced in our profile catalog.
• Trademarks: Apple, iPhone, Safari, iCloud, and iOS are trademarks of Apple Inc., registered in the U.S. and other countries. All other brand names and camera models referenced in camera profiles are the property of their respective trademark holders and are used solely for descriptive identification of hardware technical profiles.

6. Intellectual Property
All rights, title, and interest in and to the Application (excluding user-provided media), including the user interface design, layout, graphics, icon branding, compiled Swift media engine, and proprietary codebase, are owned exclusively by vxti.

7. Disclaimer of Warranties
TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, THE APPLICATION IS PROVIDED ON AN "AS IS" AND "AS AVAILABLE" BASIS, WITHOUT WARRANTIES OF ANY KIND, WHETHER EXPRESS, IMPLIED, STATUTORY, OR OTHERWISE.

VXTI EXPRESSLY DISCLAIMS ALL WARRANTIES, INCLUDING BUT NOT LIMITED TO:
• IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND NON-INFRINGEMENT.
• WARRANTIES THAT THE APPLICATION WILL OPERATE UNINTERRUPTED, SECURELY, OR ERROR-FREE.
• WARRANTIES REGARDING THE ACCURACY, RELIABILITY, OR FORENSIC VALIDITY OF ANY METADATA WRITTEN OR REMOVED.

YOU ASSUME ENTIRE RISK AS TO THE RESULTS AND PERFORMANCE OF THE APPLICATION. ALWAYS RETAIN INDEPENDENT BACKUPS OF YOUR ORIGINAL MEDIA FILES.

8. Limitation of Liability
TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, IN NO EVENT SHALL VXTI, AFFILIATES, AGENTS, OR LICENSORS BE LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, PUNITIVE, OR EXEMPLARY DAMAGES, INCLUDING BUT NOT LIMITED TO:
• LOSS OF PROFITS, DATA, USE, GOODWILL, OR OTHER INTANGIBLE LOSSES.
• CORRUPTION OR LOSS OF ANY MEDIA FILES OR METADATA.
• CLAIMS ARISING OUT OF THE DISPLAY OR NON-DISPLAY OF METADATA BY THIRD-PARTY PLATFORMS OR FORENSIC SERVICES.

UNDER NO CIRCUMSTANCES SHALL VXTI'S TOTAL AGGREGATE LIABILITY ARISING OUT OF OR IN CONNECTION WITH THESE TERMS OR THE USE OF THE APPLICATION EXCEED THE TOTAL AMOUNT ACTUALLY PAID BY YOU FOR THE APPLICATION, OR TEN UNITED STATES DOLLARS (\$10.00 USD), WHICHEVER IS GREATER.

9. Governing Law & Dispute Resolution
These Terms shall be governed by and construed in accordance with applicable laws, without regard to conflict of law principles. Any dispute arising under or relating to these Terms shall be resolved through binding confidential arbitration or in competent courts of jurisdiction.

10. Contact Information
For questions regarding these Terms of Use:
Developer & Publisher: vxti
Email: vxti.dev@gmail.com
Platform Directory: Zlarp (https://zlarp.com)
''';
}
