# menoh-haskell

[![Hackage](https://img.shields.io/hackage/v/menoh.svg)](https://hackage.haskell.org/package/menoh)
[![Hackage Deps](https://img.shields.io/hackage-deps/v/menoh.svg)](https://packdeps.haskellers.com/feed?needle=menoh)

Haskell binding for [Menoh](https://github.com/pfnet-research/menoh/) DNN inference library.

# Requirements

- [Menoh](https://github.com/pfnet-research/menoh/)
- [The Haskell Tool Stack](https://www.haskellstack.org/)

# Build

Execute below commands in root directory.

```
sh retrieve_data.sh
stack build
```

# Running VGG16 example

Execute below command in root directory.

```
cd menoh
stack exec vgg16_example
```

Result is below

```
vgg16 example
fc6_out: -19.079105 -37.94045 -16.185831 25.51685 4.432623 ...
top 5 categories are:
8 0.958079 n01514859 hen
7 0.039541963 n01514668 cock
86 0.0018722217 n01807496 partridge
82 0.00027406064 n01797886 ruffed grouse, partridge, Bonasa umbellus
97 0.00003177848 n01847000 drake
```

Please give `--help` option for details

```
stack exec vgg16_example --help
```

# Installation

```
stack install
```

# Licence

Note: `retrieve_data.sh` downloads `data/VGG16.onnx`. `data/VGG16.onnx` is generated by onnx-chainer from pre-trained model which is uploaded
at http://www.robots.ox.ac.uk/%7Evgg/software/very_deep/caffe/VGG_ILSVRC_16_layers.caffemodel

That pre-trained model is released under Creative Commons Attribution License.
