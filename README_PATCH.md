SnapLoop identity + face-profile live patch

This patch adds:
- FirebaseUserDirectory (users/{uid})
- FirebaseFaceProfileStore (users/{uid}/faceProfile/current)
- auth completion now creates/loads the Firestore user and face profile
- persisted Firebase Auth session hydration on app relaunch
- Face Setup screen (PhotosPicker for Simulator-friendly testing)
- Sign Out

Important:
- Do NOT overwrite your working FirebaseAuthService.swift or AppDelegate.swift. This patch intentionally does not include either file.
- Your current FaceDetectionService.live is still StubFaceDetectionService, so this patch proves the face-profile persistence/UI flow, NOT real face-recognition accuracy.
- EventRepository.live is NOT included here because your published Firestore rules intentionally require trusted server-side membership/invite operations. Implementing it correctly needs Cloud Functions (and Blaze billing for deployment) rather than weakening the rules.
