# Third-party notices

Flock Dotter’s first-party AGPL-3.0-only notice does not replace the following grants. Preserve the referenced full license texts, source notices and modification record when distributing the corresponding files. Bundled Help includes this overview and the full detector notices.

| Material | Rights and retained notice |
| --- | --- |
| IBM Plex Sans Regular, Semibold and Bold; IBM Plex Mono Semibold | Copyright © 2017 IBM Corp., Reserved Font Name “Plex”; SIL Open Font License 1.1. Unmodified fonts and full licenses are in `DotCounter/Resources/Fonts/OFL-IBM-Plex-Sans.txt` and `OFL-IBM-Plex-Mono.txt`. |
| CountGD code and author model weights | Copyright 2024 Niki Amini-Naieni; MIT. Full grant: `DotCounter/Resources/BirdPrototype/Notices/countgd-license.txt`. Pinned author model card declares MIT: `countgd-model-readme.md`. |
| Inherited Grounding DINO and BERT material | Apache License 2.0. Full grants and author model cards/readmes are retained in `groundingdino-license.txt`, `bert-license.txt`, `groundingdino-hf-readme.md`, `bert-readme.md` and `bert-google-readme.md` in the same Notices directory. |
| Inherited Microsoft Swin Transformer and longzw1997 Open-GroundingDino material | MIT; complete copyright notices and grants in `swin-license.txt` and `open-groundingdino-license.txt`. |
| Inherited IDEA, Microsoft, Facebook and affiliates, SenseTime and OpenMMLab source attributions | Preserve `Inherited-attributions.txt`, the MIT/Apache full grants above and `Lineage-and-modifications.txt`. These credit inherited inference material; they do not assert that every upstream package is bundled. |
| Debug snow-geese photo (`DotCounter/Resources/QA-flock.jpg`) | USFWS, public domain; source: https://www.fws.gov/media/flock-snow-geese . Original photo unchanged; demonstration markers are examples, not an asserted whole-flock total. Excluded from the public production app. |
| Runtime-test photo (`DotCounterOwnerBetaRuntimeTests/OwnerBeta-bird-fixture.jpg`) | “Blackbird-sunset-03.jpg”, Jerry Segraves (en:User:Jsegraves99), worldwide public-domain dedication on the author’s Commons page: https://commons.wikimedia.org/wiki/File:Blackbird-sunset-03.jpg . Original bytes SHA-256 `6bf5b999781f3342b01a4821ca5a30da4365658258e7245cc050457d88ca1fdc`. Test resource, excluded from the public production app. |

The selected modified graph is `CountGDFixedBird800ValidMaxFP32.mlpackage`, 540,953,605 bytes, package-tree SHA-256 `0bf005710150e5a0b1f406fac13804a59e933f26fe941cd6dc02af027eaf3047`. The weights derive from `nikigoli/CountGD` revision `6b989ad11db9413e44863ea5c57735cae6cacff8`, source weights SHA-256 `7e3baed25e5299034301b00c2647fb23503dd306c468259114a4957198424e4c`. Full pins and modification details are retained in `DotCounter/Resources/BirdPrototype/Third-party-notices.txt` and `Notices/source-notice-manifest.json`.

The conversion fixes the bird-text constants and 800-pixel FP32 graph and modifies deformable attention and proposal reduction. The native app ports image sampling, orientation and tile geometry and executes through Apple Core ML on the CPU. This is a modified integration, not the authors’ original executable or a certified equivalent. No Python runtime, PyTorch executable, optional SAM model, training photographs or training datasets are bundled with the detector. Historical training-data provenance, including Objects365 and FSC-147, is not independently certified by this project. The publisher’s MIT/Apache grants support redistribution under their terms; they are not a universal clearance of every historical dataset.

Apple frameworks and SF Symbols are used through Apple’s system SDKs; they are not relicensed under AGPL. The app links Apple system frameworks and the local DotCounterCore package, with no downloaded third-party executable dependency. Model material and fonts are separately described above.

Store screenshot photography has its own attribution in [credits](docs/public/credits.md). It is not bundled as a production fixture. User-selected photos remain subject to their owners’ rights.
