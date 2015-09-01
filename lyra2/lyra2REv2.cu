extern "C" {
#include "sph/sph_blake.h"
#include "sph/sph_bmw.h"
#include "sph/sph_skein.h"
#include "sph/sph_keccak.h"
#include "sph/sph_cubehash.h"
#include "lyra2/Lyra2.h"
}

#include "miner.h"
#include "cuda_helper.h"

extern void blakeKeccak256_cpu_hash_80(const int thr_id, const uint32_t threads, const uint32_t startNonce, uint64_t *Hash);
extern void blake256_cpu_setBlock_80(int thr_id, uint32_t *pdata);

extern void keccak256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash);
extern void keccak256_cpu_init(int thr_id, uint32_t threads);

extern void skein256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash);
extern void skein256_cpu_init(int thr_id, uint32_t threads);

extern void skeinCube256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash);


extern void lyra2v2_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash);
extern void lyra2v2_cpu_init(int thr_id, uint32_t threads, uint64_t* matrix);

extern void bmw256_setTarget(int thr_id, const void *ptarget);
extern void bmw256_cpu_init(int thr_id, uint32_t threads);
extern void bmw256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNounce, uint64_t *g_hash, uint32_t *resultnonces);

extern void cubehash256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNounce, uint64_t *d_hash);

extern "C" void lyra2v2_hash(void *state, const void *input)
{
	sph_blake256_context      ctx_blake;
	sph_keccak256_context     ctx_keccak;
	sph_skein256_context      ctx_skein;
	sph_bmw256_context        ctx_bmw;
	sph_cubehash256_context   ctx_cube;

	uint32_t hashA[8], hashB[8];

	sph_blake256_init(&ctx_blake);
	sph_blake256(&ctx_blake, input, 80);
	sph_blake256_close(&ctx_blake, hashA);

	sph_keccak256_init(&ctx_keccak);
	sph_keccak256(&ctx_keccak, hashA, 32);
	sph_keccak256_close(&ctx_keccak, hashB);

	sph_cubehash256_init(&ctx_cube);
	sph_cubehash256(&ctx_cube, hashB, 32);
	sph_cubehash256_close(&ctx_cube, hashA);


	LYRA2(hashB, 32, hashA, 32, hashA, 32, 1, 4, 4);

	sph_skein256_init(&ctx_skein);
	sph_skein256(&ctx_skein, hashB, 32);
	sph_skein256_close(&ctx_skein, hashA);

	sph_cubehash256_init(&ctx_cube);
	sph_cubehash256(&ctx_cube, hashA, 32);
	sph_cubehash256_close(&ctx_cube, hashB);


	sph_bmw256_init(&ctx_bmw);
	sph_bmw256(&ctx_bmw, hashB, 32);
	sph_bmw256_close(&ctx_bmw, hashA);

	memcpy(state, hashA, 32);
}

int scanhash_lyra2v2(int thr_id, uint32_t *pdata,
	const uint32_t *ptarget, uint32_t max_nonce,
	uint32_t *hashes_done)
{
	static THREAD uint64_t *d_hash = nullptr;
	static THREAD uint64_t *d_hash2 = nullptr;

	const uint32_t first_nonce = pdata[19];
	uint32_t intensity = 256 * 256 * 8;

	cudaDeviceProp props;
	cudaGetDeviceProperties(&props, device_map[thr_id]);
	if (strstr(props.name, "970"))
	{
		intensity = 256 * 256 * 22;
	}
	else if (strstr(props.name, "980"))
	{
		intensity = 256 * 256 * 22;
	}
	else if (strstr(props.name, "750 Ti"))
	{
		intensity = 256 * 256 * 8;
	}
	else if (strstr(props.name, "750"))
	{
		intensity = 256 * 256 * 5;
	}
	else if (strstr(props.name, "960"))
	{
		intensity = 256 * 256 * 8;
	}
	uint32_t throughput = device_intensity(device_map[thr_id], __func__, intensity);

	if (opt_benchmark)
		((uint32_t*)ptarget)[7] = 0x004f;

	static THREAD bool init = false;
	if (!init)
	{ 
		CUDA_SAFE_CALL(cudaSetDevice(device_map[thr_id]));
		cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
		cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
		CUDA_SAFE_CALL(cudaStreamCreate(&gpustream[thr_id]));

		CUDA_SAFE_CALL(cudaMalloc(&d_hash2, 16  * 4 * 4 * sizeof(uint64_t) * throughput));
		CUDA_SAFE_CALL(cudaMalloc(&d_hash, 8 * sizeof(uint32_t) * throughput));

//		keccak256_cpu_init(thr_id, throughput);
		skein256_cpu_init(thr_id, throughput);
		bmw256_cpu_init(thr_id, throughput);
        lyra2v2_cpu_init(thr_id, throughput, d_hash2);

		init = true; 
	}

	uint32_t endiandata[20];
	for (int k=0; k < 20; k++)
		be32enc(&endiandata[k], ((uint32_t*)pdata)[k]);

	blake256_cpu_setBlock_80(thr_id, pdata);
	bmw256_setTarget(thr_id, ptarget);

	do {
		uint32_t foundNonce[2] = { 0, 0 };

		blakeKeccak256_cpu_hash_80(thr_id, throughput, pdata[19], d_hash);
//		keccak256_cpu_hash_32(thr_id, throughput, pdata[19], d_hash);
		cubehash256_cpu_hash_32(thr_id, throughput, pdata[19], d_hash);
		lyra2v2_cpu_hash_32(thr_id, throughput, pdata[19], d_hash);
		skein256_cpu_hash_32(thr_id, throughput, pdata[19], d_hash);
		cubehash256_cpu_hash_32(thr_id, throughput,pdata[19], d_hash);
		bmw256_cpu_hash_32(thr_id, throughput, pdata[19], d_hash, foundNonce);
		if(stop_mining)
		{
			mining_has_stopped[thr_id] = true; cudaStreamDestroy(gpustream[thr_id]); pthread_exit(nullptr);
		}
		if(foundNonce[0] != 0)
		{
//			CUDA_SAFE_CALL(cudaGetLastError());
			const uint32_t Htarg = ptarget[7];
			uint32_t vhash64[8];
			be32enc(&endiandata[19], foundNonce[0]);
			lyra2v2_hash(vhash64, endiandata);
			if (vhash64[7] <= Htarg && fulltest(vhash64, ptarget))
			{
				int res = 1;
				// check if there was some other ones...
				*hashes_done = pdata[19] - first_nonce + throughput;
				if (foundNonce[1] != 0)
				{
					pdata[21] = foundNonce[1];
					res++;
					if (opt_benchmark)  applog(LOG_INFO, "GPU #%d Found second nonce %08x", thr_id, foundNonce[1]);
				}
				pdata[19] = foundNonce[0];
				if (opt_benchmark) applog(LOG_INFO, "GPU #%d Found nonce % 08x", thr_id, foundNonce[0]);
				return res;
			}
			else
			{
				if (vhash64[7] > Htarg) // don't show message if it is equal but fails fulltest
					applog(LOG_WARNING, "GPU #%d: result does not validate on CPU!", thr_id);
			}
		}

		pdata[19] += throughput;

	} while (!work_restart[thr_id].restart && ((uint64_t)max_nonce > ((uint64_t)(pdata[19]) + (uint64_t)throughput)));

	*hashes_done = pdata[19] - first_nonce ;
//	MyStreamSynchronize(NULL, NULL, device_map[thr_id]);
	return 0;
}