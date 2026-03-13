# Optimized Copy Shader Benchmark

This project implements an optimized version of Godot's downsampling copy shader for MIPMAP calculations.

The shader is loaded as a calcultion shader and called using Godot's low level `RenderingDevice` interface.

Several project settings were modified to avoid a backup of frames on the GPU to ensure calculations are flushed quickly. Statistics are calculated on identical data, executed in random order.