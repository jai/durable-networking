import unittest

import relay


class VpcResolverTest(unittest.TestCase):
    def test_network_plus_two(self) -> None:
        self.assertEqual(relay.vpc_resolver("172.31.0.0/16"), "172.31.0.2")
        self.assertEqual(relay.vpc_resolver("10.20.48.0/20"), "10.20.48.2")

    def test_host_bits_are_masked(self) -> None:
        self.assertEqual(relay.vpc_resolver("10.0.0.7/24"), "10.0.0.2")
