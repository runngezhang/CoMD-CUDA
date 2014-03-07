/*************************************************************************
 * Copyright (c) 2013, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 ************************************************************************/

#include <stdio.h>
#include <assert.h>

#include "CoMDTypes.h"
#include "haloExchange.h"

#include "gpu_types.h"
#include "gpu_timestep.h"
#include "defines.h"

#include "gpu_utility.h"

#include "gpu_common.h"
#include "gpu_redistribute.h"
#include "gpu_neighborList.h"

#include "gpu_lj_thread_atom.h"
#include "gpu_eam_thread_atom.h"
#include "gpu_eam_warp_atom.h"
#include "gpu_eam_cta_cell.h"

#include "gpu_scan.h"
#include "gpu_reduce.h"

#include "hashTable.h"

extern "C"
int neighborListUpdateRequiredGpu(SimGpu* sim);

extern "C"
void ljForceGpu(SimGpu sim)
{
  cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
  int grid = (sim.a_list.n + (THREAD_ATOM_CTA-1))/ THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;
  LJ_Force_thread_atom<<<grid, block>>>(sim, sim.a_list);
}

template<int step>
int compute_eam_smem_size(SimGpu sim)
{
  int smem = 0;

  // neighbors data
  // positions
  smem += 3 * sizeof(real_t) * CTA_CELL_CTA;

  // embed force
  if (step == 3)
    smem += sizeof(real_t) * CTA_CELL_CTA;

  // local data
  // forces
  smem += 3 * sim.max_atoms_cell * sizeof(real_t);

  // positions
  smem += 3 * sim.max_atoms_cell * sizeof(real_t);

  // ie, irho
  if (step == 1) 
    smem += 2 * sim.max_atoms_cell * sizeof(real_t);

  // local neighbor list
  smem += (CTA_CELL_CTA / WARP_SIZE) * 64 * sizeof(char);

  return smem;
}

template<int step>
void eamForce(SimGpu sim, AtomListGpu atoms_list, int num_cells, int *cells_list, int method, cudaStream_t stream = NULL)
{
  assert(method <= 3);
  if (method == 0) { 
    
    int grid = (atoms_list.n + (THREAD_ATOM_CTA-1))/ THREAD_ATOM_CTA;
    int block = THREAD_ATOM_CTA;
    EAM_Force_thread_atom<step><<<grid, block, 0, stream>>>(sim, atoms_list);
  }
  else if (method == 1) {
    int block = WARP_ATOM_CTA;
    int grid = (atoms_list.n + (WARP_ATOM_CTA/WARP_SIZE)-1)/ (WARP_ATOM_CTA/WARP_SIZE);
    EAM_Force_warp_atom<step><<<grid, block, 0, stream>>>(sim, atoms_list);
  } 
  else if (method == 2) {
    cudaDeviceSetCacheConfig(cudaFuncCachePreferShared); // necessary for good occupancy
    int block = CTA_CELL_CTA;
    int grid = num_cells;
    int smem = compute_eam_smem_size<step>(sim);
    EAM_Force_cta_cell<step><<<grid, block, smem, stream>>>(sim, cells_list);
    cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
  }else if (method == 3) { 
    
    int grid = (atoms_list.n + (THREAD_ATOM_CTA-1))/ THREAD_ATOM_CTA;
    int block = THREAD_ATOM_CTA;
    EAM_Force_thread_atom_NL<step><<<grid, block, 0, stream>>>(sim, atoms_list);
  }
}

template<>
void eamForce<2>(SimGpu sim, AtomListGpu atoms_list, int num_cells, int *cells_list, int method, cudaStream_t stream)
{
  assert(method <= 3);
  if (method == 0 || method == 1 || method == 3) {
    int grid = (atoms_list.n + (THREAD_ATOM_CTA-1))/ THREAD_ATOM_CTA;
    int block = THREAD_ATOM_CTA;
    EAM_Force_thread_atom<2><<<grid, block, 0, stream>>>(sim, atoms_list);
  }
  else if (method == 2) {
    int grid = num_cells;
    int block = CTA_CELL_CTA;
    EAM_Force_cta_cell<2><<<grid, block, 0, stream>>>(sim, cells_list);
  }
}

extern "C"
void updateNeighborsGpuAsync(SimGpu sim, int *temp, int nCells, int *cellList, cudaStream_t stream)
{
  // update # of neighbor atoms per cell - 1 thread per cell
  int block = THREAD_ATOM_CTA;
  int grid = (nCells + (block-1))/ block;
  UpdateNeighborNumAtoms<<<grid, block, 0, stream>>>(sim, nCells, cellList, temp);

  // update atom indices - 1 CTA per cell
  grid = nCells;
  UpdateNeighborAtomIndices<<<grid, block, 0, stream>>>(sim, nCells, cellList, temp);
}

extern "C"
void updateNeighborsGpu(SimGpu sim, int *temp)
{
  // update # of neighbor atoms per cell - 1 thread per cell
  int block = THREAD_ATOM_CTA;
  int grid = (sim.boxes.nLocalBoxes + (block-1))/ block;
  UpdateNeighborNumAtoms<<<grid, block>>>(sim, sim.boxes.nLocalBoxes, NULL, temp);

  // update atom indices - 1 CTA per cell
  grid = sim.boxes.nLocalBoxes;
  UpdateNeighborAtomIndices<<<grid, block>>>(sim, sim.boxes.nLocalBoxes, NULL, temp);
}

extern "C"
void eamForce1Gpu(SimGpu sim, int method)
{
  cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
  eamForce<1>(sim, sim.a_list, sim.boxes.nLocalBoxes, NULL, method);
}

// async launch, latency hiding opt
extern "C" 
void eamForce1GpuAsync(SimGpu sim, AtomListGpu atoms_list, int num_cells, int *cells_list, int method, cudaStream_t stream)
{
  cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
  eamForce<1>(sim, atoms_list, num_cells, cells_list, method, stream);
}

extern "C"
void eamForce2Gpu(SimGpu sim, int method)
{
  eamForce<2>(sim, sim.a_list, sim.boxes.nLocalBoxes, NULL, method);
}

extern "C"
void eamForce2GpuAsync(SimGpu sim, AtomListGpu atoms_list, int num_cells, int *cells_list, int method, cudaStream_t stream)
{
  eamForce<2>(sim, atoms_list, num_cells, cells_list, method, stream);
}

extern "C"
void eamForce3Gpu(SimGpu sim, int method)
{
  eamForce<3>(sim, sim.a_list, sim.boxes.nLocalBoxes, NULL, method);
}

extern "C" 
void eamForce3GpuAsync(SimGpu sim, AtomListGpu atoms_list, int num_cells, int *cells_list, int method, cudaStream_t stream)
{
  eamForce<3>(sim, atoms_list, num_cells, cells_list, method, stream);
}

extern "C"
void advanceVelocityGpu(SimGpu sim, real_t dt)
{
  int grid = (sim.a_list.n + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;
  AdvanceVelocity<<<grid, block>>>(sim, dt);
}

extern "C"
void advancePositionGpu(SimGpu* sim, real_t dt)
{
  int grid = (sim->a_list.n + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;
  AdvancePosition<<<grid, block>>>(*sim, dt);

  //TODO: this functionality should not be here. It seems like a nasty side-effect. REFACTORING!
  sim->atoms.neighborList.updateNeighborListRequired = -1; //next call to neighborListUpdateRequired() will loop over all particles 
}


/// Launch one thread per cell and fill cellOffsets with the number of atoms of each cell (used for scan).
/// @param [out] cellOffsets
/// @param [in] nCells
/// @param [in] cellList ID of every cell
/// @param [in] num_atoms number of atoms for each cell (of size nTotalBoxes) 
__global__ void fill(int *cellOffsets, int nCells, int *cellList, int *num_atoms)
{
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid < nCells)
    cellOffsets[tid] = num_atoms[cellList[tid]];
  else if (tid == nCells)
    cellOffsets[tid] = 0;
}

__global__ void fill(int *cellOffsets, int nCells, int *num_atoms)
{
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid < nCells)
    cellOffsets[tid] = num_atoms[tid];
  else if (tid == nCells)
    cellOffsets[tid] = 0;
}

/// Computes the scan of number of atoms of the speciefied cell IDs (specified by cellList).
/// @param [in] nCell number of cells
/// @param [in] cellList ID of every cell
/// @param [in] num_atoms number of atoms for each cell (of size nTotalBoxes) 
/// @param [out] nAtomsOffset result of the scan.
/// @param [out] work Temporary array with minimum size of ceil((nCell+1)/256)
void scanCells(int *d_cellOffsets, int nCells, int *cellList, int *num_atoms, int *work, cudaStream_t stream = NULL)
{
  // natoms[i] = num_atoms[cellList[i]]
  int block = THREAD_ATOM_CTA;
  int grid = (nCells + 1 + block-1) / block;
  fill<<<grid, block, 0, stream>>>(d_cellOffsets, nCells, cellList, num_atoms);

  // scan to compute linear index
  scan(d_cellOffsets, nCells + 1, work, stream);
}

void scanCells(int *natoms_buf, int nCells, int *num_atoms, int *work, cudaStream_t stream = NULL)
{
  // natoms[i] = num_atoms[i]
  int block = THREAD_ATOM_CTA;
  int grid = (nCells + 1 + block-1) / block;
  fill<<<grid, block, 0, stream>>>(natoms_buf, nCells, num_atoms);

  // scan to compute linear index
  scan(natoms_buf, nCells + 1, work, stream);
}

void BuildAtomLists(SimFlat *s)
{
  int nCells = s->boxes->nLocalBoxes;
  int n_interior_cells = s->boxes->nLocalBoxes - s->n_boundary_cells;

  int size = nCells+1;
  if (size % 256 != 0) size = ((size + 255)/256)*256;

  int *cell_offsets1;
  int *cell_offsets2;
  cudaMalloc(&cell_offsets1, size * sizeof(int));
  cudaMalloc(&cell_offsets2, size * sizeof(int));
  int *partial_sums;
  cudaMalloc(&partial_sums, size * sizeof(int));

  scanCells(cell_offsets1, nCells, s->gpu.boxes.nAtoms, partial_sums);

  int block = THREAD_ATOM_CTA;
  int grid = (nCells + (block/WARP_SIZE)-1)/(block/WARP_SIZE);
  UpdateAtomList<<<grid, block>>>(s->gpu, s->gpu.a_list, nCells, cell_offsets1);   

  // build interior & boundary lists
  scanCells(cell_offsets1, s->n_boundary_cells, s->boundary_cells, s->gpu.boxes.nAtoms, partial_sums);
  scanCells(cell_offsets2, n_interior_cells, s->interior_cells, s->gpu.boxes.nAtoms, partial_sums);

  grid = (s->n_boundary_cells + (block/WARP_SIZE)-1)/(block/WARP_SIZE);
  UpdateBoundaryList<<<grid, block>>>(s->gpu, s->gpu.b_list, s->n_boundary_cells, cell_offsets1, s->boundary_cells);   

  grid = (n_interior_cells + (block/WARP_SIZE)-1)/(block/WARP_SIZE);
  UpdateBoundaryList<<<grid, block>>>(s->gpu, s->gpu.i_list, n_interior_cells, cell_offsets2, s->interior_cells);   

  cudaMemcpy(&s->gpu.b_list.n, cell_offsets1 + s->n_boundary_cells, sizeof(int), cudaMemcpyDeviceToHost);
  cudaMemcpy(&s->gpu.i_list.n, cell_offsets2 + n_interior_cells, sizeof(int), cudaMemcpyDeviceToHost);

  cudaFree(cell_offsets1);
  cudaFree(cell_offsets2);
}

/// \details
/// This is the first step in returning data structures to a consistent
/// state after the atoms move each time step.  First we discard all
/// atoms in the halo link cells.  These are all atoms that are
/// currently stored on other ranks and so any information we have about
/// them is stale.  Next, we move any atoms that have crossed link cell
/// boundaries into their new link cells.  It is likely that some atoms
/// will be moved into halo link cells.  Since we have deleted halo
/// atoms from other tasks, it is clear that any atoms that are in halo
/// cells at the end of this routine have just transitioned from local
/// to halo atoms.  Such atom must be sent to other tasks by a halo
/// exchange to avoid being lost.
/// \see redistributeAtoms
extern "C"
void updateLinkCellsGpu(SimFlat *sim)
{
  int *flags = sim->flags;

  //empty haloCells
  cudaMemset(sim->gpu.boxes.nAtoms + sim->boxes->nLocalBoxes, 0, (sim->boxes->nTotalBoxes - sim->boxes->nLocalBoxes) * sizeof(int));

  // set all flags to 0
  cudaMemset(flags, 0, sim->boxes->nTotalBoxes * MAXATOMS * sizeof(int));
 
  // 1 thread updates 1 atom
  int grid = (sim->gpu.a_list.n + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;
  UpdateLinkCells<<<grid, block>>>(sim->gpu, sim->gpu.boxes, flags);

  // 1 thread updates 1 cell
  grid = (sim->boxes->nLocalBoxes + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  block = THREAD_ATOM_CTA;
  CompactAtoms<<<grid, block>>>(sim->gpu, sim->boxes->nLocalBoxes, flags);

  // update max # of atoms per cell
  cudaMemcpy(&sim->gpu.max_atoms_cell, &flags[sim->boxes->nLocalBoxes * MAXATOMS], sizeof(int), cudaMemcpyDeviceToHost);

  // build new atom lists: only for thread/atom or warp/atom approaches
  if (sim->method == 0 || sim->method == 1 || sim->method == 3)
    BuildAtomLists(sim);
}

extern "C"
void getAtomMsgSoAPtr(char* const buffer, AtomMsgSoA *atomMsg, int n)
{
        atomMsg->gid  =  (int*) buffer;
        atomMsg->type = atomMsg->gid + n;
        atomMsg->rx = (real_t*)(atomMsg->type + n);
        atomMsg->ry = atomMsg->rx + n;
        atomMsg->rz = atomMsg->rx + 2*n;
        atomMsg->px = atomMsg->rx + 3*n;
        atomMsg->py = atomMsg->rx + 4*n;
        atomMsg->pz = atomMsg->rx + 5*n;
}

/// compacts all particles within all the cells specified by cellList into compactAtoms (see AtomMsgSoA for data layout)
/// @param [out] d_compactAtoms Device-pointer, On-exit: stores the compacted atoms in SoA format.
/// @param [in] nCells number of cells in cellList
/// @param [in] cellList Device-pointer. Holds the cell id of the cells of interest
/// @param [in] nAtomsCell Device-pointer. Holds the number of cells of each cell (most likely sim->boxes->nAtoms)
/// @param [out] d_cellOffsets Device-pointer. On-exit: Contains the starting offsets for each cell within d_compactAtoms. (e.g.: numAtoms(0)=3, numAtoms(1)=2 => cellOffsets(0)=0,cellOffsets(1)=3,cellOffsets(2)=5)
extern "C"
int compactCellsGpu(char* d_compactAtoms, int nCells, int *d_cellList, SimGpu sim_gpu, int* d_cellOffsets, int * d_workScan, real3_old shift, cudaStream_t stream)
{

    // compute starting offsets for each cell within the compacted array
    scanCells(d_cellOffsets, nCells, d_cellList, sim_gpu.boxes.nAtoms, d_workScan, stream);

    int nTotalAtomsCellList;
    // the last entry of d_nAtomsOffset will store the total number of atoms within all specified cells
    cudaMemcpyAsync(&nTotalAtomsCellList, d_cellOffsets + nCells, sizeof(int), cudaMemcpyDeviceToHost, stream);
    cudaStreamSynchronize(stream);

    //alias host and device buffers with AtomMsgSoA
    AtomMsgSoA msg_d;
    getAtomMsgSoAPtr(d_compactAtoms, &msg_d, nTotalAtomsCellList);

    //assemble compact array of particles
    int block = MAXATOMS;
    int grid = nCells;
    LoadAtomsBufferPacked<<<grid, block,0,stream>>>(msg_d, d_cellList, sim_gpu, d_cellOffsets, shift[0], shift[1], shift[2]);

    return nTotalAtomsCellList;
}

/// builds sim->gpu.a_list
/// @param [out] natoms_buf (temporary)
/// @param [out] partial_sums (temporary)
extern "C"
void buildAtomListGpu(SimFlat *sim, cudaStream_t stream)
{
  int* natoms_buf = ((AtomExchangeParms*)(sim->atomExchange->parms))->d_natoms_buf;
  int *partial_sums = ((AtomExchangeParms*)(sim->atomExchange->parms))->d_partial_sums;
  int nCells = sim->boxes->nLocalBoxes;
  scanCells(natoms_buf, nCells, sim->gpu.boxes.nAtoms, partial_sums, stream);

  // rebuild compact list of atoms & cells
  int grid = (nCells * MAXATOMS + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;
  UpdateCompactIndices<<<grid, block, 0, stream>>>(natoms_buf, nCells, sim->gpu);

  // new number of local atoms
  cudaMemcpyAsync(&(sim->gpu.a_list.n), natoms_buf + nCells, sizeof(int), cudaMemcpyDeviceToHost, stream);
}

/// The unloadBuffer function for a halo exchange of atom data.
/// Iterates the receive buffer and places each atom that was received
/// into the link cell that corresponds to the atom coordinate.  Note
/// that this naturally accomplishes transfer of ownership of atoms that
/// have moved from one spatial domain to another.  Atoms with
/// coordinates in local link cells automatically become local
/// particles.  Atoms that are owned by other ranks are automatically
/// placed in halo kink cells.
/// @param bBuf [in] Total number of received atoms
/// @param buf [in] Pointer to the received data
/// @param sim [inout] The gpu field of sim will be updated
/// @param gpu_buf [out] Already allocated gpu buffer (temporary)
extern "C"
void unloadAtomsBufferToGpu(char *buf, int nBuf, SimFlat *sim, char *gpu_buf, cudaStream_t stream)
{
  cudaMemcpyAsync(gpu_buf, buf, nBuf * sizeof(AtomMsg), cudaMemcpyHostToDevice, stream);

  // TODO: don't need to check if we're running cell-based approach
  int nlUpdateRequired = neighborListUpdateRequiredGpu(&(sim->gpu));

  int grid = (nBuf + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;

  vec_t r,p;
  int *gid = (int*)gpu_buf;
  int *type = gid + nBuf;
  r.x = (real_t*)(type + nBuf);
  r.y = r.x + nBuf;
  r.z = r.y + nBuf;
  p.x = r.z + nBuf;
  p.y = p.x + nBuf;
  p.z = p.y + nBuf;

  // use temp arrays
  int *d_iOffset = sim->flags;
  int *d_boxId = sim->tmp_sort;

  computeOffsets(nlUpdateRequired, sim, r, d_iOffset, d_boxId, nBuf, stream);

  // map received particles to cells
  UnloadAtomsBufferPacked<<<grid, block, 0, stream>>>(r, p, type, gid, nBuf, sim->gpu.atoms, d_iOffset);
}

/// The loadBuffer function for a force exchange.
/// Iterate the send list and load the derivative of the embedding
/// energy with respect to the local density into the send buffer.
extern "C"
void loadForceBufferFromGpu(char *buf, int *nbuf, int nCells, int *cellList, int *natoms_buf, int *partial_sums, SimFlat *s, char *gpu_buf, cudaStream_t stream)
{
  scanCells(natoms_buf, nCells, cellList, s->gpu.boxes.nAtoms, partial_sums, stream);

  // copy data to compacted array
  int grid = (nCells * MAXATOMS + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;
  LoadForceBuffer<<<grid, block, 0, stream>>>((ForceMsg*)gpu_buf, nCells, cellList, s->gpu, natoms_buf);

  int nBuf;
  cudaMemcpyAsync(&nBuf, natoms_buf + nCells, sizeof(int), cudaMemcpyDeviceToHost, stream);
  cudaMemcpyAsync(buf, gpu_buf, nBuf * sizeof(ForceMsg), cudaMemcpyDeviceToHost, stream);

  cudaStreamSynchronize(stream);
  *nbuf = nBuf;
}

/// The unloadBuffer function for a force exchange.
/// Data is received in an order that naturally aligns with the atom
/// storage so it is simple to put the data where it belongs.
extern "C"
void unloadForceBufferToGpu(char *buf, int nBuf, int nCells, int *cellList, int *natoms_buf, int *partial_sums, SimFlat *s, char *gpu_buf, cudaStream_t stream)
{
  // copy raw data to gpu
  cudaMemcpyAsync(gpu_buf, buf, nBuf * sizeof(ForceMsg), cudaMemcpyHostToDevice, stream);

  scanCells(natoms_buf, nCells, cellList, s->gpu.boxes.nAtoms, partial_sums, stream);

  // copy data for the list of cells
  int grid = (nCells * MAXATOMS + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;
  UnloadForceBuffer<<<grid, block, 0, stream>>>((ForceMsg*)gpu_buf, nCells, cellList, s->gpu, natoms_buf);
}

extern "C"
void sortAtomsGpu(SimFlat *s, cudaStream_t stream)
{
  int *new_indices = s->flags;
  // set all indices to -1
  cudaMemsetAsync(new_indices, 255, s->boxes->nTotalBoxes * MAXATOMS * sizeof(int), stream);
  
  // one thread per atom, only update boundary cells
  int block = MAXATOMS;
  int grid = (s->n_boundary1_cells * WARP_SIZE + block-1)/block;
  SetLinearIndices<<<grid, block, 0, stream>>>(s->gpu, s->n_boundary1_cells, s->boundary1_cells_d, new_indices);

  // update halo cells
  grid = ((s->boxes->nTotalBoxes - s->boxes->nLocalBoxes) * MAXATOMS + block-1)/block;
  SetLinearIndices<<<grid, block, 0, stream>>>(s->gpu, s->boxes->nLocalBoxes, s->boxes->nTotalBoxes, new_indices);

  // one thread per cell: process halo & boundary cells only
  int block2 = MAXATOMS;
  int grid2 = (s->n_boundary1_cells + (s->boxes->nTotalBoxes - s->boxes->nLocalBoxes) + block2-1) / block2;
  SortAtomsByGlobalId<<<grid2, block2, 0, stream>>>(s->gpu, s->boxes->nLocalBoxes, s->boxes->nTotalBoxes, s->boundary1_cells_d, s->n_boundary1_cells, new_indices, s->tmp_sort);

  // one warp per cell
  int block3 = THREAD_ATOM_CTA;
  int grid3 = ((s->n_boundary1_cells + (s->boxes->nTotalBoxes - s->boxes->nLocalBoxes)) * WARP_SIZE + block3-1) / block3;
  ShuffleAtomsData<<<grid3, block3, 0, stream>>>(s->gpu, s->boxes->nLocalBoxes, s->boxes->nTotalBoxes, s->boundary1_cells_d, s->n_boundary1_cells, new_indices);
}

extern "C"
void computeEnergy(SimFlat *flat, real_t *eLocal)
{
  real_t *e_gpu;
  cudaMalloc(&e_gpu, 2 * sizeof(real_t));
  cudaMemset(e_gpu, 0, 2 * sizeof(real_t));

  int grid = (flat->gpu.a_list.n + (THREAD_ATOM_CTA-1)) / THREAD_ATOM_CTA;
  int block = THREAD_ATOM_CTA;
  ReduceEnergy<<<grid, block>>>(flat->gpu, &e_gpu[0], &e_gpu[1]);
  
  cudaMemcpy(eLocal, e_gpu, 2 * sizeof(real_t), cudaMemcpyDeviceToHost);
}

__global__
void emptyNeighborListGpuKernel(SimGpu sim, int boundaryFlag)
{
  int tid = blockIdx.x * blockDim.x + threadIdx.x; 
  if (tid >= sim.a_list.n) return;

  // compute box ID and local atom ID
  int iBox = sim.a_list.cells[tid]; 
  if (boundaryFlag == INTERIOR && sim.cell_type[iBox] != 0) return;
  if (boundaryFlag == BOUNDARY && sim.cell_type[iBox] != 1) return;
  sim.atoms.neighborList.nNeighbors[tid] = 0;
}

/// Sets all neighbor counts to zero
extern "C"
void emptyNeighborListGpu(SimGpu *sim, int boundaryFlag)
{
   
    int grid = (sim->a_list.n + (THREAD_ATOM_CTA-1))/ THREAD_ATOM_CTA;
    int block = THREAD_ATOM_CTA;
    emptyNeighborListGpuKernel<<<grid,block>>>(*sim, boundaryFlag);
}

__global__
__launch_bounds__(THREAD_ATOM_CTA, THREAD_ATOM_ACTIVE_CTAS)
void updateNeighborListRequriedKernel(SimGpu sim, int* updateNeighborListRequired)
{
  int tid = blockIdx.x * blockDim.x + threadIdx.x; 
  if (tid >= sim.a_list.n) return;

  // compute box ID and local atom ID
  int iAtom = sim.a_list.atoms[tid];
  int iBox = sim.a_list.cells[tid]; 
  int iOff = iBox * MAXATOMS + iAtom;

  // fetch position
  real_t dx = sim.atoms.r.x[iOff] - sim.atoms.neighborList.lastR.x[tid];
  real_t dy = sim.atoms.r.y[iOff] - sim.atoms.neighborList.lastR.y[tid];
  real_t dz = sim.atoms.r.z[iOff] - sim.atoms.neighborList.lastR.z[tid];
 
  if( (dx*dx + dy*dy + dz*dz) > sim.atoms.neighborList.skinDistanceHalf2 )
          *updateNeighborListRequired = 1;
}

/// \param [inout] neighborList NeighborList (the only value that might be changed is updateNeighborListRequired
/// \return 1 iff neighborlist update is required in this step
extern "C"
int neighborListUpdateRequiredGpu(SimGpu* sim)
{
        
        if(sim->atoms.neighborList.forceRebuildFlag== 1){
                sim->atoms.neighborList.updateNeighborListRequired = 1; 
        }else if(sim->atoms.neighborList.updateNeighborListRequired == -1){
//        }else {
                //only do a real neighborlistupdate check if the particles have moved (indicated by updateNeighborListRequired == -1)
                int grid = (sim->a_list.n + (THREAD_ATOM_CTA-1))/ THREAD_ATOM_CTA;
                int block = THREAD_ATOM_CTA;

                int *d_updateNeighborListRequired;
                int h_updateNeighborListRequired; 
                cudaMalloc(&d_updateNeighborListRequired, sizeof(int));

                cudaMemset(d_updateNeighborListRequired, 0, sizeof(int));
                updateNeighborListRequriedKernel<<<grid, block>>>(*sim, d_updateNeighborListRequired);

                cudaMemcpy(&h_updateNeighborListRequired,d_updateNeighborListRequired, sizeof(int), cudaMemcpyDeviceToHost);

                int tmpUpdateNeighborListRequired = h_updateNeighborListRequired;
                //TODO this function needs to be called for multi-node correctness. However, there are (most likely) other things that case bugs with the 
                //multi-node version but this is one thing that definitely needs to be done. It just assure that if one node has to rebuild its NL, then
                //all nodes have to do so.
//                maxIntParallel(&h_updateNeighborListRequired, &tmpUpdateNeighborListRequired, 1); 
                cudaFree(d_updateNeighborListRequired);

                if(tmpUpdateNeighborListRequired > 0)
                        sim->atoms.neighborList.updateNeighborListRequired = 1; 
                else
                        sim->atoms.neighborList.updateNeighborListRequired = 0; 
        }

        return  sim->atoms.neighborList.updateNeighborListRequired;
}

__global__
__launch_bounds__(THREAD_ATOM_CTA, THREAD_ATOM_ACTIVE_CTAS)
void buildNeighborListKernel(SimGpu sim, int boundaryFlag)
{
  int tid = blockIdx.x * blockDim.x + threadIdx.x; 
  if (tid >= sim.a_list.n) return;

  // compute box ID and local atom ID
  int iAtom = sim.a_list.atoms[tid];
  int iBox = sim.a_list.cells[tid]; 

  assert(sim.cell_type[iBox] == 0 || sim.cell_type[iBox] == 1);
  if(boundaryFlag == BOUNDARY && sim.cell_type[iBox] == 0) return;
  if(boundaryFlag == INTERIOR && sim.cell_type[iBox] == 1) return;

  int iOff = iBox * MAXATOMS + iAtom;

  real_t rCut = sim.eam_pot.cutoff;
  real_t rCut2 = (rCut+sim.atoms.neighborList.skinDistance)*(rCut+sim.atoms.neighborList.skinDistance);

  // fetch position
  real_t irx = sim.atoms.r.x[iOff];
  real_t iry = sim.atoms.r.y[iOff];
  real_t irz = sim.atoms.r.z[iOff];

  //get NL related data
  int iLid = tid; 
  const int ldNeighborList = sim.atoms.neighborList.nMaxLocal; //leading dimension
  assert(iLid<ldNeighborList);
  int* neighborList = sim.atoms.neighborList.list;
  int nNeighbors = 0;
  sim.atoms.neighborList.lastR.x[iLid] = irx;
  sim.atoms.neighborList.lastR.y[iLid] = iry;
  sim.atoms.neighborList.lastR.z[iLid] = irz;
 
  real_t *const __restrict__ rx = sim.atoms.r.x;
  real_t *const __restrict__ ry = sim.atoms.r.y;
  real_t *const __restrict__ rz = sim.atoms.r.z;

  // loop over my neighbor cells
  for (int j = 0; j < N_MAX_NEIGHBORS; j++) 
  { 
    int jBox = sim.neighbor_cells[iBox * N_MAX_NEIGHBORS + j];

    // loop over all atoms in the neighbor cell 
    for (int jAtom = 0; jAtom < sim.boxes.nAtoms[jBox]; jAtom++) 
    {  
      int jOff = jBox * MAXATOMS + jAtom; 

      real_t dx = irx - rx[jOff];
      real_t dy = iry - ry[jOff];
      real_t dz = irz - rz[jOff];

      // distance^2
      real_t r2 = dx*dx + dy*dy + dz*dz;

      // no divide by zero
      if (r2 <= rCut2 && r2 > 0.0) 
      {
         assert(nNeighbors < sim.atoms.neighborList.nMaxNeighbors); // TODO enlarge neighborlist (this should be fine for now)
         neighborList[nNeighbors * ldNeighborList + iLid ] = jOff;
         ++nNeighbors;
      } 
    } // loop over all atoms
  } // loop over neighbor cells
  sim.atoms.neighborList.nNeighbors[iLid] = nNeighbors;
}

/// Build the neighbor list for all boxes which are marked as dirty.
extern "C"
void buildNeighborListGpu(SimGpu* sim, int boundaryFlag)
{
   NeighborListGpu* neighborList = &(sim->atoms.neighborList); 
   
   if(neighborListUpdateRequiredGpu(sim) == 1){
           emptyNeighborListGpu(sim, boundaryFlag);
           
           int grid = (sim->a_list.n + (THREAD_ATOM_CTA-1))/ THREAD_ATOM_CTA;
           int block = THREAD_ATOM_CTA;
           buildNeighborListKernel<<<grid, block>>>(*sim, boundaryFlag);

           neighborList->nStepsSinceLastBuild = 1;
           neighborList->updateNeighborListRequired = 0;
           neighborList->forceRebuildFlag = 0;
   }else
           neighborList->nStepsSinceLastBuild++;
}

extern "C"
void emptyHashTableGpu(HashTableGpu* hashTable)
{
   hashTable->nEntriesPut = 0;
}

extern "C"
void initHashTableGpu(HashTableGpu* hashTable, int nMaxEntries)
{

   hashTable->nMaxEntries = nMaxEntries; 
   hashTable->nEntriesPut = 0; //allocates a 5MB hashtable. This number is prime.
   hashTable->nEntriesGet = 0; //allocates a 5MB hashtable. This number is prime.

   cudaMalloc(&(hashTable->offset), sizeof(int) * hashTable->nMaxEntries);

}

