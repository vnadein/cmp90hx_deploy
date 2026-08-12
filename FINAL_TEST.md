# LOCK

## 1xCmp90hx

| model                          |       size |     params | backend    | ngl |   main_gpu |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --------------: | -------------------: |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | Vulkan     |  99 |          1 |           pp512 |        160.92 ± 0.01 |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | Vulkan     |  99 |          1 |           tg128 |         37.20 ± 0.00 |

## 3xCmp90hx

| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | Vulkan     |  99 |           pp512 |        129.94 ± 3.13 |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | Vulkan     |  99 |           tg128 |         11.01 ± 4.50 |

---

# UNLOCK

## 1xCmp90hx

| model                          |       size |     params | backend    | ngl |   main_gpu |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | ---------: | --------------: | -------------------: |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | Vulkan     |  99 |          1 |           pp512 |      2655.57 ± 23.29 |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | Vulkan     |  99 |          1 |           tg128 |        108.25 ± 0.10 |

## 3xCmp90hx

| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | Vulkan     |  99 |           pp512 |      1283.66 ± 13.19 |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | Vulkan     |  99 |           tg128 |        51.47 ± 14.53 |

---

# PACTHING LLAMA (UNLOCK)

## 1xCmp90hx

| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | CUDA       |  99 |           pp512 |     3568.25 ± 276.00 |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | CUDA       |  99 |           tg128 |        139.43 ± 0.07 |

## 3xCmp90hx

| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | CUDA       |  99 |           pp512 |      1535.78 ± 15.43 |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | CUDA       |  99 |           tg128 |        125.96 ± 1.09 |

---

# PACTHING LLAMA (UNLOCK) BIG MODEL COMPARE WITH TESLA V100 32GB LLAMA STOCK

## 3xCmp90hx

| model                                      |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| nemotron_h_moe 31B.A3.5B Q5_K - Medium     |  24.40 GiB |    31.58 B | CUDA       |  99 |           pp512 |      1498.20 ± 57.95 |
| nemotron_h_moe 31B.A3.5B Q5_K - Medium     |  24.40 GiB |    31.58 B | CUDA       |  99 |           tg128 |        111.99 ± 1.06 |

## 1xTESLA V100 32GB

| model                                      |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| nemotron_h_moe 31B.A3.5B Q5_K - Medium     |  24.40 GiB |    31.58 B | CUDA       |  99 |           pp512 |      1761.73 ± 10.07 |
| nemotron_h_moe 31B.A3.5B Q5_K - Medium     |  24.40 GiB |    31.58 B | CUDA       |  99 |           tg128 |        145.15 ± 1.21 |
