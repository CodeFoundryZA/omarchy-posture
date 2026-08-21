# Third party notices

This plugin bundles third party components. They keep their own licenses.

## BlazePose pose estimation model

- File: `models/pose_estimation_mediapipe_2023mar.onnx`
- Source: [opencv_zoo](https://github.com/opencv/opencv_zoo), `models/pose_estimation_mediapipe`
- Upstream: MediaPipe BlazePose, converted to ONNX by the OpenCV Zoo project
- License: Apache License 2.0
- SHA-256: `9d89c599319a18fb7d2e28451a883476164543182bafca5f09eb2cf767ed2f3f`

## BlazePose decoder

- File: `lib/mp_pose.py`
- Source: [opencv_zoo](https://github.com/opencv/opencv_zoo), `models/pose_estimation_mediapipe/mp_pose.py`
- License: Apache License 2.0
- Used unmodified. The region of interest normally supplied by the upstream
  person detector is synthesised by this plugin instead; see the README.

A copy of the Apache License 2.0 is available at
<https://www.apache.org/licenses/LICENSE-2.0>.

## Runtime dependency

`python-opencv` (OpenCV, Apache License 2.0) is required but not bundled. It is
installed from the distribution's own repositories.
