/* The vh-hashpw hash is verified by libcrypt itself: crypt(password, hash) == hash. */
#include <crypt.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
	if (argc != 3)
		return 2;
	const char *h = crypt(argv[1], argv[2]);
	return h && strcmp(h, argv[2]) == 0 ? 0 : 1;
}
