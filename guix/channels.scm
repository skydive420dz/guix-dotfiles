(list
 (channel
  (name 'guix)
  (url "https://git.guix.gnu.org/guix.git")
  (branch "master")
  (commit "a8391f2d7451c2463ba253ffa9872fa6f27485d7")
  (introduction
   (make-channel-introduction
    "9edb3f66fd807b096b48283debdcddccfea34bad"
    (openpgp-fingerprint
     "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA"))))
 (channel
  (name 'nonguix)
  (url "https://gitlab.com/nonguix/nonguix")
  (branch "master")
  (commit "3b66965566fe8c96edb5a41fd39a9e5a90ad9b61")
  (introduction
   (make-channel-introduction
    "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
    (openpgp-fingerprint
     "2A39 3FFF 68F4 EF7A 3D29 12AF 6F51 20A0 22FB B2D5"))))
 (channel
  (name 'sk-guix)
  (url "https://github.com/skydive420dz/sk-guix.git")
  (branch "main")
  (commit "b84ff24a515b2b6d0db85c0da30960c96e20ad22")
  (introduction
   (make-channel-introduction
    "eaade3680892ce74ebae68f4922cd0eb4a463a17"
    (openpgp-fingerprint
     "6B09 4D15 B02E 54B0 F6B5  E9E8 6F83 FC62 D232 E5EC")))))
