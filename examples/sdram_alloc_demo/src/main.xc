#include "platform.h"
#include "xs1.h"

#include "math.h"
#include "sdram.h"
#include "memory_address_allocator.h"

#include "debug_print.h"
#include "xassert.h"

/* Configure XCORE200 Slicekit TILE 0 Triangle port for SDRAM slice */
on tile[2] : out buffered port:32 sdram_dq_ah = XS1_PORT_16B;
on tile[2] : out buffered port:32 sdram_cas = XS1_PORT_1J;
on tile[2] : out buffered port:32 sdram_ras = XS1_PORT_1I;
on tile[2] : out buffered port:8 sdram_we = XS1_PORT_1K;
on tile[2] : out port sdram_clk = XS1_PORT_1L;
on tile[2] : clock sdram_cb = XS1_CLKBLK_2;

/* N defines the number of words to write/read in a single burst. */
#define N (1024)
#define RAMBYTES (256*1024*1024) /* 256 MB total SDRAM */

void application(streaming chanend c_sdram_server, client interface memory_address_allocator_i i_mem_alloc)
{
    debug_printf("Got here!\n");

    /* Declare and initialize the SDRAM server task. */
    s_sdram_state sdram_state;
    sdram_init_state(c_sdram_server, sdram_state);

    /* Create two buffers, fill one with a pattern and the other with
     * zeros. After writing the first buffer to RAM and reading it into
     * the second buffer the contents of the buffers should match.  */
    unsigned wordcount = 0;
    unsigned buffer_0[N];
    unsigned buffer_1[N];

    for(int i = 1; i < N; i++)
    {

        buffer_0[i] = (i-N/2)*(i-N/2)*(i-N/2);
        buffer_1[i] = 0;

    }

    /* Request blocks of RAM until no more can be allocated */
    unsigned address;
    double avg_write_time=0;
    double avg_read_time=0;
    while(!i_mem_alloc.request((N*sizeof(unsigned)), address))
    {
        unsigned t_start;
        unsigned t_write;
        unsigned t_read;
        {
            /* The SDRAM API uses movable pointers. When a movable pointer goes out of scope
             * it must return ownership to the state it was in at initialization. That is why
             * these operations are in their own scope {}.*/
            timer t;
            unsigned * movable buffer_pointer_0 = buffer_0;
            unsigned * movable buffer_pointer_1 = buffer_1;
            t :> t_start;
            sdram_write(c_sdram_server, sdram_state, address, N, move(buffer_pointer_0));
            sdram_complete(c_sdram_server, sdram_state, buffer_pointer_0);
            t :> t_write;
            sdram_read(c_sdram_server, sdram_state, address, N, move(buffer_pointer_1));
            sdram_complete(c_sdram_server, sdram_state, buffer_pointer_1);
            t :> t_read;
            /* Movable pointers must exit scope where they were initialized. */
        }
        /* Averages (presently sums) assume write then read. */
        avg_write_time += (t_write - t_start);
        avg_read_time += (t_read - t_write);

        /* Check that the correct data was read into the destination buffer. */
        for(int i = 0; i < N; i++)
        {
            xassert(buffer_0[i] == buffer_1[i]);
        }
        wordcount += N;
    }
    sdram_shutdown(c_sdram_server);
    debug_printf("%d MB successfully tested!\n",(wordcount*sizeof(unsigned))/(1024*1024));

    /* Complete average computation. */
    avg_write_time = (avg_write_time*N / wordcount)*0.01;
    avg_read_time = (avg_read_time*N / wordcount)*0.01;

    debug_printf("Average write time for %d word burst: %d us\n", N, (int)round(avg_write_time));
    debug_printf("Average read time for %d word burst: %d us\n", N, (int)round(avg_read_time));

}

int main() {

    streaming chan c_sdram[1];
interface    memory_address_allocator_i mem_alloc_i[1];

    par {

        // 256 MB SDRAM
        on tile[2]:
    sdram_server(c_sdram, 1, sdram_dq_ah, sdram_cas, sdram_ras, sdram_we,
            sdram_clk, sdram_cb, 2,    //CAS latency
            128,  //Row long words
            16,   //Col bits (argument unused by server)
            8,    //Col addr bits
            12,   //Row bits
            2,    //Bank bits
            64,   //Milliseconds refresh
            4096, //Refresh cycles
            4)
    ;   //Clock divider

    on tile[2]: application(c_sdram[0], mem_alloc_i[0])
    ;
    on tile[2]: memory_address_allocator(1, mem_alloc_i, 0, RAMBYTES)
    ;
}

return 0;
}
