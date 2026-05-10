# Test images for KV260 demo

Drop a few cat and dog `.jpg` images here for `host/notebooks/inference_demo.ipynb`
and `host/notebooks/benchmark.ipynb`. These get rsynced to the board by
`host/scripts/deploy.sh`.

## Naming convention

The notebook defaults to `samples/dog_01.jpg`. For variety, drop ~10–20 images
with prefixes that match the class label:

```
samples/
├── cat_01.jpg
├── cat_02.jpg
├── ...
├── dog_01.jpg
├── dog_02.jpg
└── ...
```

`benchmark.ipynb` globs `samples/*.jpg` and infers the ground-truth label from
the filename prefix.
